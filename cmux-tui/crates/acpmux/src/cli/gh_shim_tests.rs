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
