use super::*;

#[test]
fn the_successor_gets_this_daemons_flags_but_not_its_fds() {
    let args: Vec<String> = [
        "acp",
        "daemon",
        "run",
        "--ready-fd",
        "3",
        "--memory",
        "--person-key-fd=4",
        "--take-over",
        "--dev",
    ]
    .map(String::from)
    .to_vec();
    assert_eq!(handover_args(&args), ["acp", "daemon", "run", "--take-over", "--memory", "--dev"]);
}
