use super::shell_quote;

#[test]
fn argv_mode_quotes_shell_metacharacters_and_single_quotes() {
    assert_eq!(shell_quote("cargo"), "cargo");
    assert_eq!(shell_quote("hello world"), "'hello world'");
    assert_eq!(shell_quote("it's"), "'it'\\''s'");
    assert_eq!(shell_quote("$(touch /tmp/nope)"), "'$(touch /tmp/nope)'");
}
