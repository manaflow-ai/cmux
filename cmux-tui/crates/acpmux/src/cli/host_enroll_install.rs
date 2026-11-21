//! Bootstrap a foreign-platform standalone daemon from the same checked
//! channel as machine-join.sh and host self-update. No shell-profile edits.

use super::*;

pub(super) fn bootstrap(r: &dyn Remote, bin: &str, target: &str) -> StepResult {
    let next = format!("Check outbound HTTPS on {}, then add the machine again.", r.host());
    // A standalone acpmux cannot replace the app's cmux-tui executable.
    if bin.rsplit('/').next() != Some("acpmux") {
        return fail(
            Step::Install,
            format!("cannot install standalone acpmux as {bin}"),
            INSTALL_FROM_APP.replace("{host}", r.host()),
        )
        .with_reason(REASON_NOT_THIS_PROGRAM);
    }
    let install = || -> Result<String> {
        let lock = hosts::lock_to_install(r)?;
        let fenced = lock.fence(r);
        let r: &dyn Remote = &fenced;
        let url = hosts::channel_url("feat-cmux-next")?;
        let body = hosts::run(
            r,
            &format!(
                r#"set -eu
acpmux_manifest=$(mktemp)
trap 'rm -f "$acpmux_manifest"' EXIT
trap 'exit 130' HUP INT TERM
(ulimit -f 128; curl --proto '=https' --tlsv1.2 -fsS --max-time 30 --max-filesize 65536 {} -o "$acpmux_manifest")
cat "$acpmux_manifest""#,
                shell_quote(&url)
            ),
        )?;
        anyhow::ensure!(body.len() <= 65536, "the channel exceeds 64 KiB");
        let channel = hosts::Channel::parse(body.as_bytes())?;
        let sha = channel.sha256_for(target)?;
        let url = channel.binary_url(target);
        hosts::run(r, &download_script(bin, &url, sha))?;
        if bin != DAEMON_BIN {
            link_daemon_bin(r, bin)?;
        }
        let (installed, daemon) = installed(r, bin)?;
        anyhow::ensure!(
            installed.is_some() && installed == daemon,
            "the downloaded acpmux did not answer its version through {bin} and {DAEMON_BIN}"
        );
        Ok(installed.unwrap_or_default())
    };
    match install() {
        Ok(build) => StepResult::new(
            Step::Install,
            StepState::Fixed,
            format!("installed acpmux for {target} (build {build})"),
        ),
        Err(e) => fail(Step::Install, format!("installing acpmux for {target}: {e:#}"), next),
    }
}

/// Run only while holding the host's update lock. Stage beside the destination
/// so rename is atomic, including when HOME and TMPDIR are different filesystems.
/// Failed downloads/checks never replace the installed file or its backup.
fn download_script(bin: &str, url: &str, sha: &str) -> String {
    format!(
        r#"set -eu
umask 077
acpmux_bin={bin}
acpmux_dir=$(dirname "$acpmux_bin")
mkdir -p "$acpmux_dir"
acpmux_tmp=$(mktemp -d "$acpmux_dir/.acpmux-install.XXXXXX")
trap 'rm -rf "$acpmux_tmp"' EXIT
trap 'exit 130' HUP INT TERM
# Also bound streamed responses on older curl versions (ulimit units are
# 512 or 1024 bytes depending on the shell, so this caps at most 512 MiB).
(ulimit -f 524288; curl --proto '=https' --tlsv1.2 -fsS --max-time 600 --max-filesize 536870912 {url} -o "$acpmux_tmp/acpmux")
if command -v sha256sum >/dev/null 2>&1; then
    acpmux_sum=$(sha256sum "$acpmux_tmp/acpmux" | awk '{{print $1}}')
else
    acpmux_sum=$(shasum -a 256 "$acpmux_tmp/acpmux" | awk '{{print $1}}')
fi
[ "$acpmux_sum" = {sha} ] || {{ echo 'acpmux checksum verification failed; nothing was installed' >&2; exit 1; }}
chmod 755 "$acpmux_tmp/acpmux"
"$acpmux_tmp/acpmux" --version >/dev/null
if [ -e "$acpmux_bin" ]; then
    cp -p "$acpmux_bin" "$acpmux_tmp/previous"
    mv -f "$acpmux_tmp/previous" "$acpmux_bin.prev"
fi
mv -f "$acpmux_tmp/acpmux" "$acpmux_bin"
"#,
        // bin was checked by install() as a plain shell path; keep ~ expansion.
        url = shell_quote(url),
        sha = shell_quote(sha)
    )
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn bootstrap_download_checks_bytes_before_atomic_install() {
        let dir = tempfile::tempdir().unwrap();
        let destination = dir.path().join("acpmux");
        let payload = "#!/bin/sh\necho 'acpmux 0.1.0 (published)'\n";
        let source = dir.path().join("download");
        std::fs::write(&source, payload).unwrap();
        let sum = crate::sha256::sha256_hex(payload.as_bytes());
        let run = |sha: &str, curl: &str| {
            let script = format!(
                "{curl}\n{}",
                download_script(destination.to_str().unwrap(), "https://files.cmux.com/test", sha)
            );
            std::process::Command::new("sh").args(["-c", &script]).output().unwrap()
        };
        let curl = format!(
            "curl() {{ for arg do last=$arg; done; cp {} \"$last\"; }}",
            shell_quote(source.to_str().unwrap())
        );
        std::fs::write(&destination, "existing").unwrap();
        std::fs::write(destination.with_extension("prev"), "previous").unwrap();
        let bad = run(&"0".repeat(64), &curl);
        assert!(!bad.status.success());
        assert!(String::from_utf8_lossy(&bad.stderr).contains("checksum verification failed"));
        assert_eq!(std::fs::read_to_string(&destination).unwrap(), "existing");
        assert_eq!(
            std::fs::read_to_string(destination.with_extension("prev")).unwrap(),
            "previous"
        );
        let failed = run(&sum, "curl() { return 22; }");
        assert!(!failed.status.success());
        assert_eq!(std::fs::read_to_string(&destination).unwrap(), "existing");
        let good = run(&sum, &curl);
        assert!(good.status.success(), "{}", String::from_utf8_lossy(&good.stderr));
        assert_eq!(std::fs::read_to_string(&destination).unwrap(), payload);
        assert_eq!(
            std::fs::read_to_string(destination.with_extension("prev")).unwrap(),
            "existing"
        );
        assert_eq!(
            std::fs::read_dir(dir.path()).unwrap().count(),
            3,
            "staging folders are removed"
        );
    }
}
