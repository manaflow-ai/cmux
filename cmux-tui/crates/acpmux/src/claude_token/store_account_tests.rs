use super::*;

#[test]
fn only_accounts_new_account_makes_reach_the_keychain() {
    assert!(is_account(&new_account("claude-token")));
    assert!(is_account(&new_account("vertex-express")));
    assert!(is_account("openai-0123abcd"));
    for bad in [
        "",
        "openai",
        "openai-0123ABCD",
        "openai-0123abc",
        "-0123abcd",
        "../x-0123abcd",
        "a/b-0123abcd",
        "Open AI-0123abcd",
        "openai-0123abcd\n",
    ] {
        assert!(!is_account(bad), "{bad:?}");
    }
}

#[test]
fn a_secret_with_a_line_break_is_refused_before_the_keychain() {
    assert!(keychain_store(&new_account("test"), "label", "a\nb").is_err());
    assert!(keychain_store(&new_account("test"), "label", "a\0b").is_err());
}
