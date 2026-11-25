//! Stream changed names through confined Git attribute queries. Only the
//! generated paths returned to the viewer stay in memory, plus one triplet.

use std::collections::HashSet;
use std::io;
use std::process::Stdio;

use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::process::Command;

use super::{
    DiffSource, SESSION_GIT_TIMEOUT, SessionGit, SessionOpenError, Whitespace, git_merge_base,
    git_untracked_paths,
};

/// Changed paths whose `.gitattributes` mark them generated. Attribute
/// failures remain best effort, so they never prevent a session opening.
pub(super) async fn git_generated_paths(
    source: &DiffSource,
    whitespace: Whitespace,
    git: &SessionGit,
) -> Vec<String> {
    let Ok(mut names_command) = changed_paths_command(source, whitespace, git).await else {
        return Vec::new();
    };
    // Match the unstaged patch's current untracked enumeration. Its separate
    // bounds belong to patch capture, not to the tracked attribute stream.
    let untracked = if matches!(source, DiffSource::Unstaged { .. }) {
        git_untracked_paths(git).await.unwrap_or_default()
    } else {
        Vec::new()
    };
    names_command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let Ok(mut names_child) = names_command.spawn() else {
        return Vec::new();
    };
    let mut attributes_command = git.command();
    attributes_command
        .args(["check-attr", "-z", "--stdin", "linguist-generated", "diff"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let Ok(mut attributes_child) = attributes_command.spawn() else {
        let _ = names_child.kill().await;
        let _ = names_child.wait().await;
        return Vec::new();
    };
    let result = tokio::time::timeout(SESSION_GIT_TIMEOUT, async {
        let names = names_child.stdout.take().ok_or_else(missing_pipe)?;
        let input = attributes_child.stdin.take().ok_or_else(missing_pipe)?;
        let output = attributes_child.stdout.take().ok_or_else(missing_pipe)?;
        // Read results while writing names: either pipe can fill on a large
        // diff. Git receives raw NUL-separated names without argument limits
        // or a whole-list copy in this process.
        let ((), generated, names_status, attributes_status) = tokio::try_join!(
            feed_names(names, input, untracked),
            collect_generated(output),
            names_child.wait(),
            attributes_child.wait(),
        )?;
        if !names_status.success() || !attributes_status.success() {
            return Err(io::Error::other("git attribute query failed"));
        }
        Ok(generated)
    })
    .await;
    if let Ok(Ok(generated)) = result {
        return generated;
    }
    // Reap both producers on failure or timeout. kill_on_drop also covers
    // cancellation by the enclosing session-open deadline or RPC shutdown.
    let _ = names_child.kill().await;
    let _ = attributes_child.kill().await;
    let _ = names_child.wait().await;
    let _ = attributes_child.wait().await;
    Vec::new()
}

fn missing_pipe() -> io::Error {
    io::Error::other("git attribute pipe unavailable")
}

async fn feed_names(
    mut names: impl AsyncRead + Unpin,
    mut input: impl AsyncWrite + Unpin,
    untracked: Vec<String>,
) -> io::Result<()> {
    tokio::io::copy(&mut names, &mut input).await?;
    for path in untracked {
        input.write_all(path.as_bytes()).await?;
        input.write_all(&[0]).await?;
    }
    input.shutdown().await
}

async fn collect_generated(output: impl AsyncRead + Unpin) -> io::Result<Vec<String>> {
    let mut output = BufReader::new(output);
    let (mut path, mut attribute, mut value) = (Vec::new(), Vec::new(), Vec::new());
    let mut seen = HashSet::new();
    let mut generated = Vec::new();
    // `-z` produces path NUL attribute NUL value NUL triplets. Keep framing
    // across arbitrary pipe boundaries, including Unicode and newline paths.
    while read_field(&mut output, &mut path).await? {
        if !read_field(&mut output, &mut attribute).await?
            || !read_field(&mut output, &mut value).await?
        {
            return Err(io::Error::other("incomplete git attribute triplet"));
        }
        let marks_generated = match attribute.as_slice() {
            b"linguist-generated" => value == b"set" || value == b"true",
            b"diff" => value == b"unset",
            _ => false,
        };
        if marks_generated {
            let path = String::from_utf8_lossy(&path).into_owned();
            if seen.insert(path.clone()) {
                generated.push(path);
            }
        }
    }
    Ok(generated)
}

async fn read_field(
    output: &mut (impl AsyncBufRead + Unpin),
    field: &mut Vec<u8>,
) -> io::Result<bool> {
    field.clear();
    if output.read_until(0, field).await? == 0 {
        return Ok(false);
    }
    if field.pop() != Some(0) {
        return Err(io::Error::other("unterminated git attribute field"));
    }
    Ok(true)
}

/// Mirror the exact source and whitespace options used to capture the patch.
async fn changed_paths_command(
    source: &DiffSource,
    whitespace: Whitespace,
    git: &SessionGit,
) -> Result<Command, SessionOpenError> {
    let mut command = git.command();
    command.args([
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--name-only",
        "-z",
    ]);
    command.args(whitespace.diff_args());
    match source {
        DiffSource::Unstaged { .. } => {}
        DiffSource::Staged { .. } => {
            command.arg("--cached");
        }
        DiffSource::Branch {
            base_ref: Some(base_ref),
            ..
        } => {
            command.arg(git_merge_base(git, base_ref).await?);
        }
        DiffSource::Branch { base_ref: None, .. } | DiffSource::Patch { .. } => {
            return Err(SessionOpenError::Failed);
        }
    }
    command.arg("--");
    Ok(command)
}
