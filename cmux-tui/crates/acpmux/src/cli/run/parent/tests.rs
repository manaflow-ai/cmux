use super::*;

fn new_args(words: &[&str]) -> NewArgs {
    #[derive(clap::Parser)]
    struct New {
        #[command(flatten)]
        args: NewArgs,
    }
    let argv = std::iter::once("new").chain(words.iter().copied());
    <New as clap::Parser>::try_parse_from(argv).unwrap().args
}

#[test]
fn a_child_start_names_its_parent_harness_model_and_effort() {
    let args = new_args(&["--parent", "lead", "-m", "codex/gpt-5.5", "-e", "high", "-n", "t"]);
    assert_eq!(refused_flags(&args), None);
    let p = start_params(&args, "lead", "fix it").unwrap();
    assert_eq!(
        p,
        json!({"parent": "lead", "prompt": "fix it", "harness": "codex", "model": "gpt-5.5",
                   "effort": "high", "name": "t"})
    );
}

#[test]
fn force_admit_reaches_the_child_start() {
    let args = new_args(&["--parent", "lead", "--force-admit", "go"]);
    assert_eq!(refused_flags(&args), None);
    let p = start_params(&args, "lead", "go").unwrap();
    assert_eq!(p["_meta"]["acpmux"]["forceAdmit"], true, "{p}");
    let p = start_params(&new_args(&["--parent", "lead", "go"]), "lead", "go").unwrap();
    assert!(p.get("_meta").is_none(), "{p}");
}

#[test]
fn a_turn_end_reads_as_its_state_and_error() {
    let ok = json!({"status": "completed", "stopReason": "end_turn"});
    assert_eq!(turn_end(&ok), ("done", None));
    let failed = json!({"status": "failed", "errorText": "no credit"});
    assert_eq!(turn_end(&failed), ("failed", Some("no credit".to_owned())));
    // A turn that never started (`fail_unstarted_turn`) before it said `errorText`.
    let unstarted = json!({"status": "failed", "error": "agent gone"});
    assert_eq!(turn_end(&unstarted), ("failed", Some("agent gone".to_owned())));
    assert_eq!(turn_end(&json!({"status": "cancelled"})).0, "cancelled");
    assert_eq!(turn_end(&Value::Null).0, "failed");
}

#[test]
fn flags_a_child_start_takes_no_part_of_are_refused() {
    let why = refused_flags(&new_args(&["--parent", "lead", "--host", "box", "go"]));
    assert_eq!(why.as_deref(), Some("--parent takes no --machine: a family lives on one daemon"));
    assert!(refused_flags(&new_args(&["--parent", "lead", "--policy", "ask"])).is_some());
    assert!(refused_flags(&new_args(&["--parent", "lead", "--ephemeral"])).is_some());
}
