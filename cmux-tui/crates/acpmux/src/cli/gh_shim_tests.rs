use super::*;

fn parse(line: &str) -> Result<GithubActionParams> {
    let args: Vec<String> = line.split_whitespace().map(str::to_owned).collect();
    request(&args, &|| Ok("here/repo".to_owned()), &|path| Ok(format!("<{path}>")), &|| {
        Ok("agent/current".to_owned())
    })
}

/// The review of #24797 at c3634e0: leftover words and flags were dropped, so a command became
/// a different one (`--edit-last` a new comment, `repo delete` a read).
#[test]
fn a_flag_or_word_of_another_command_is_refused_not_dropped() {
    for line in [
        "issue comment 42 --repo o/r --body x --edit-last",
        "repo delete o/r",
        "repo view o/r --yes",
        "pr view 3 --web",
        "pr create --draft --title t --fill",
        "pr merge 3 --repo o/r",
        "issue create --title t --assignee me",
        "issue comment 42 43 --body x",
        "push --repo o/r --branch b --sha s",
        "api repos/o/r",
    ] {
        assert!(parse(line).is_err(), "{line}");
    }
}

#[test]
fn each_supported_form_names_its_action() {
    let r = parse("issue comment #42 -R o/r -b hi").unwrap();
    assert_eq!(
        (r.action, r.issue, r.repo.as_str(), r.body.as_deref()),
        (GithubAction::Comment, Some(42), "o/r", Some("hi"))
    );
    let r = parse("repo view o/r").unwrap();
    assert_eq!((r.action, r.repo.as_str()), (GithubAction::Read, "o/r"));
    let r = parse("pr view 3").unwrap();
    assert_eq!((r.action, r.issue, r.repo.as_str()), (GithubAction::Read, Some(3), "here/repo"));
    let r = parse("pr create --draft --title=T --body-file b.md --base main").unwrap();
    assert_eq!(
        (r.branch.as_deref(), r.body.as_deref(), r.base.as_deref()),
        (Some("agent/current"), Some("<b.md>"), Some("main"))
    );
}

#[test]
fn only_a_draft_pull_request_and_one_body_and_repo() {
    assert!(parse("pr create --title t").is_err());
    assert!(parse("issue create --title t --body a --body-file b").is_err());
    assert!(parse("repo view o/r --repo o/s").is_err());
    assert!(parse("issue create --title a --title b").is_err());
}

#[test]
fn github_remote_urls_name_their_repository() {
    assert_eq!(github_repo("git@github.com:o/r.git").as_deref(), Some("o/r"));
    assert_eq!(github_repo("https://github.com/o/r").as_deref(), Some("o/r"));
    assert_eq!(github_repo("ssh://git@github.com/o/r.git").as_deref(), Some("o/r"));
    assert_eq!(github_repo("https://gitlab.com/o/r"), None);
    assert_eq!(github_repo("https://github.com/o"), None);
    assert_eq!(github_repo("https://github.com/o/r.git.git").as_deref(), Some("o/r.git"));
}

/// The review of the Add Machine part at 8ca6cd7: `--body-file /dev/zero` was read whole.
#[test]
fn a_body_past_the_limit_is_refused_without_reading_on() {
    let endless = std::io::repeat(b'a');
    let e = read_bounded(endless).unwrap_err();
    assert!(e.to_string().contains("over 64 KiB"), "{e}");
    let at_limit = vec![b'a'; crate::github_broker::TEXT_MAX];
    assert_eq!(read_bounded(&at_limit[..]).unwrap().len(), crate::github_broker::TEXT_MAX);
    assert!(read_bounded(&[0xff_u8][..]).is_err());
}

/// Review of part 3 at a51f607: `git` was read whole and waited on with no limit.
#[test]
fn a_git_answer_past_its_limit_or_time_is_refused() {
    let sh = |script: &str| {
        let mut cmd = std::process::Command::new("sh");
        cmd.args(["-c", script]);
        cmd
    };
    let second = std::time::Duration::from_secs(1);
    assert_eq!(
        bounded_output(sh("echo git@github.com:o/r.git"), 64, second).unwrap(),
        "git@github.com:o/r.git"
    );
    let long = bounded_output(sh("yes"), 64, std::time::Duration::from_secs(10)).unwrap_err();
    assert!(long.to_string().contains("over 64 bytes"), "{long}");
    let started = std::time::Instant::now();
    let slow = bounded_output(sh("exec sleep 30"), 64, second).unwrap_err();
    assert!(slow.to_string().contains("took over"), "{slow}");
    assert!(started.elapsed() < std::time::Duration::from_secs(10));
    assert!(bounded_output(sh("exit 1"), 64, second).is_err());
}

/// Review of part 3 at f21dd4d: a child that closed its stdout and went on was waited for with
/// no limit, and a body FIFO with no writer blocked forever.
#[test]
fn a_git_that_closes_its_output_and_runs_on_or_a_body_that_never_comes_is_refused() {
    let second = std::time::Duration::from_secs(1);
    let mut cmd = std::process::Command::new("sh");
    cmd.args(["-c", "echo o/r; exec >&-; sleep 30"]);
    let started = std::time::Instant::now();
    let e = bounded_output(cmd, 64, second).unwrap_err();
    assert!(e.to_string().contains("took over"), "{e}");
    assert!(started.elapsed() < std::time::Duration::from_secs(10));

    let dir = std::env::temp_dir().join(format!("ghshim-fifo-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let fifo = dir.join("body");
    let _ = std::fs::remove_file(&fifo);
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let e = read_body_within(fifo.to_str().unwrap(), second).unwrap_err();
    assert!(e.to_string().contains("did not arrive"), "{e}");
    let file = dir.join("ok");
    std::fs::write(&file, "hello").unwrap();
    assert_eq!(read_body_within(file.to_str().unwrap(), second).unwrap(), "hello");
    let _ = std::fs::remove_dir_all(&dir);
}
