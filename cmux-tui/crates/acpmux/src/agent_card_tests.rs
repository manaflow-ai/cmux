use super::*;
use crate::context_inventory::{
    APPEND_SYSTEM_PROMPT, DEVELOPER_INSTRUCTIONS, USER_CONTEXT, append_snapshot, launch_args,
    snapshot_for,
};
use serde_json::json;

fn facts(place: Place) -> MachineFacts {
    MachineFacts {
        place,
        vcpus: 4,
        ram_bytes: Some(8_200_000_000),
        disk_free_bytes: Some(41_000_000_000),
        disk_total_bytes: Some(64_000_000_000),
        gpus: Some(Vec::new()),
        tools: vec!["git".into(), "node".into(), "cargo".into()],
    }
}

/// Leo's "running a big build in memory it doesn't have": a Cloud card says what its RAM means
/// for a big build and that it has no GPU; a local card says neither.
#[test]
fn a_cloud_card_says_what_its_ram_means_for_a_big_build_and_names_its_gpu() {
    let cloud = facts(Place::AutoCloud).line();
    assert!(cloud.contains("no GPU"), "{cloud}");
    assert!(cloud.contains("needing more than 8.2 GB RAM gets killed here"), "{cloud}");
    assert!(cloud.contains("`cmux vm resize`") && cloud.contains("-j4"), "{cloud}");
    assert!(cloud.contains("With no GPU"), "{cloud}");
    let with_gpu = MachineFacts { gpus: Some(vec!["NVIDIA L4".into()]), ..facts(Place::Cloud) };
    let line = with_gpu.line();
    assert!(line.contains("GPU: NVIDIA L4") && !line.contains("With no GPU"), "{line}");
    let local = facts(Place::Local).line();
    assert!(!local.contains("gets killed"), "{local}");
    let mac = MachineFacts { gpus: None, ..facts(Place::Local) }.line();
    assert!(!mac.contains("GPU"), "{mac}");
}

/// GPUs are read from the NVIDIA driver's directory, then `/dev`.
#[test]
fn gpus_are_read_from_the_driver_then_dev() {
    let root = tempfile::tempdir().unwrap();
    let nvidia = root.path().join("nvidia");
    let dev = root.path().join("dev");
    std::fs::create_dir_all(dev.join("dri")).unwrap();
    assert!(gpus_in(&nvidia, &dev).is_empty());
    std::fs::write(dev.join("dri/renderD128"), "").unwrap();
    assert_eq!(gpus_in(&nvidia, &dev), vec!["GPU (render node)"]);
    std::fs::write(dev.join("nvidia0"), "").unwrap();
    std::fs::write(dev.join("nvidiactl"), "").unwrap();
    assert_eq!(gpus_in(&nvidia, &dev), vec!["NVIDIA GPU"]);
    std::fs::create_dir_all(nvidia.join("0000:00:04.0")).unwrap();
    std::fs::write(nvidia.join("0000:00:04.0/information"), "Model: \t NVIDIA L4\nIRQ: 1\n")
        .unwrap();
    assert_eq!(gpus_in(&nvidia, &dev), vec!["NVIDIA L4"]);
}

fn servers(names: &[&str]) -> Vec<String> {
    names.iter().map(|n| (*n).to_owned()).collect()
}

fn profile(json: serde_json::Value) -> crate::config::HarnessProfile {
    serde_json::from_value(json).unwrap()
}

/// The card a Cloud chat gets says where it is, that edits sync back, that the machine grows,
/// lists the enabled capabilities and ends with the machine's real numbers.
#[test]
fn a_cloud_card_says_edits_sync_back_and_the_machine_grows_and_ends_with_its_numbers() {
    let all = servers(&[
        agent_tools::CMUX_SERVER,
        crate::acpmux_mcp_names::SERVER_NAME,
        crate::cloud_repo_mcp::SERVER_NAME,
    ]);
    let text = render(&facts(Place::Cloud), &enabled(Place::Cloud, &all));
    assert!(text.starts_with("<where-you-are>\nYou're on cmux Cloud"), "{text}");
    assert!(text.contains("edits sync back to the Mac"), "{text}");
    assert!(text.contains("This machine grows on demand"), "{text}");
    assert!(text.contains("Never call it too small"), "{text}");
    assert!(text.contains("`cmux link access request PATH`"), "{text}");
    assert!(text.contains("browser pane"), "{text}");
    assert!(text.contains("GitHub repository"), "{text}");
    assert!(text.contains("details: `cmux capabilities`"), "{text}");
    let numbers = "This machine now: 4 vCPU, 8.2 GB RAM, 41 GB disk free of 64 GB, no GPU. Tools on PATH: git, node, cargo.";
    assert!(text.contains(numbers), "{text}");
    // The numbers come last, so a prompt cache keeps everything before them.
    let last = text.lines().rev().nth(1).unwrap();
    assert!(last.starts_with("This machine now:"), "{text}");
    let auto = render(&facts(Place::AutoCloud), &enabled(Place::AutoCloud, &all));
    assert!(auto.starts_with("<where-you-are>\nYou're on cmux AutoCloud"), "{auto}");
    assert!(auto.contains("edits sync back to the Mac"), "{auto}");
}

/// Only what is enabled for the chat: no computer use without its server, no Cloud-only lines
/// on the person's own computer, nothing tool-backed for a chat without tools.
#[test]
fn the_card_lists_only_what_the_chats_tools_and_place_enable() {
    let ids = |place, names: &[&str]| -> Vec<&str> {
        enabled(place, &servers(names)).iter().map(|c| c.id).collect()
    };
    assert_eq!(ids(Place::Local, &[]), vec!["move"]);
    assert_eq!(ids(Place::Cloud, &[]), vec!["move", "grow", "folders"]);
    let local =
        ids(Place::Local, &[agent_tools::CMUX_SERVER, crate::computer_use::mcp::SERVER_NAME]);
    assert_eq!(local, vec!["browser", "rich-output", "computer-use", "move"]);
    let cloud = ids(Place::Cloud, &[crate::acpmux_mcp_names::SERVER_NAME]);
    assert!(!cloud.contains(&"computer-use"), "{cloud:?}");
    assert!(cloud.contains(&"ask") && cloud.contains(&"background"), "{cloud:?}");
    assert!(cloud.contains(&"helpers") && cloud.contains(&"machines"), "{cloud:?}");
    let local_card = render(&facts(Place::Local), &enabled(Place::Local, &[]));
    assert!(local_card.contains("on the person's own computer"), "{local_card}");
    assert!(!local_card.contains("grows on demand"), "{local_card}");
}

/// Every harness gets the card on its own rules channel with this machine's real numbers:
/// Claude in its system prompt, Codex as developer instructions, any other agent in its first
/// message.
#[test]
fn every_harness_gets_the_card_with_this_machines_numbers() {
    let home = tempfile::tempdir().unwrap();
    let vcpus = std::thread::available_parallelism().unwrap().get();
    let want = format!("This machine now: {vcpus} vCPU");
    let mut cfg = crate::config::Config::default();
    let claude = profile(json!({"kind":"claude-stdio","argv":["claude"]}));
    let codex = profile(json!({"argv":["codex","app-server"],
        "env":{"CODEX_HOME": home.path().to_string_lossy()}}));
    let other = profile(json!({"argv":["opencode","acp"]}));
    cfg.harnesses.insert("claude".into(), claude.clone());
    cfg.harnesses.insert("codex".into(), codex.clone());
    cfg.harnesses.insert("opencode".into(), other);
    let cwd = home.path();
    for (harness, channel, launch) in [
        ("claude", APPEND_SYSTEM_PROMPT, Some(&claude)),
        ("codex", DEVELOPER_INSTRUCTIONS, Some(&codex)),
        ("opencode", USER_CONTEXT, None),
    ] {
        let parts = snapshot_for(&cfg, cwd, harness, false);
        let card = parts.iter().find(|p| p.source == SOURCE).unwrap_or_else(|| panic!("{harness}"));
        assert_eq!(card.channel.as_deref(), Some(channel), "{harness}");
        assert!(card.text.as_deref().unwrap().contains(&want), "{harness}");
        // The card is the last rule, so its numbers end the rules text.
        assert_eq!(parts.last().unwrap().source, SOURCE, "{harness}");
        match launch {
            Some(p) => {
                let args = launch_args(Some(&parts), p, cwd);
                assert!(args.last().unwrap().contains(&want), "{harness}: {args:?}");
            }
            None => {
                let mut blocks = Vec::new();
                append_snapshot(Some(&parts), &mut blocks);
                let card = blocks.last().unwrap()["text"].as_str().unwrap();
                assert!(card.starts_with("<cmux-card-context>"), "{card}");
                assert!(card.contains(&want), "{card}");
            }
        }
    }
    // A remote client's chat gets no cmux context, and so no card.
    assert!(!snapshot_for(&cfg, cwd, "claude", true).iter().any(|p| p.source == SOURCE));
}

#[test]
fn the_switch_turns_the_card_off_for_a_profile() {
    let mut cfg = crate::config::Config::default();
    let off =
        profile(json!({"kind":"claude-stdio","argv":["claude"],"env":{"CMUX_AGENT_CARD":"0"}}));
    cfg.harnesses.insert("claude".into(), off);
    let parts = snapshot_for(&cfg, Path::new("/"), "claude", false);
    assert!(!parts.iter().any(|p| p.source == SOURCE), "{parts:?}");
}

/// A spawn after a resize or a move rewrites the numbers, on the channel the card was captured
/// on; a chat captured without a card gets none.
#[test]
fn a_spawn_refreshes_stale_numbers_on_the_same_channel() {
    let stale = render(&facts(Place::Cloud), &[]);
    let mut parts = vec![part_on(stale.clone(), DEVELOPER_INSTRUCTIONS)];
    let env = BTreeMap::new();
    assert!(refresh(&mut parts, &env, Path::new("/"), false));
    let text = parts[0].text.as_deref().unwrap();
    assert_ne!(text, stale);
    let vcpus = std::thread::available_parallelism().unwrap().get();
    assert!(text.contains(&format!("This machine now: {vcpus} vCPU")), "{text}");
    assert_eq!(parts[0].channel.as_deref(), Some(DEVELOPER_INSTRUCTIONS));
    assert!(!refresh(&mut parts, &env, Path::new("/"), false), "unchanged numbers: no rewrite");
    let mut none: Vec<ContextPart> = Vec::new();
    assert!(!refresh(&mut none, &env, Path::new("/"), false));
}

#[test]
fn facts_read_this_machine() {
    let facts = MachineFacts::read(Place::Local, Path::new("/"));
    assert!(facts.vcpus >= 1);
    #[cfg(target_os = "linux")]
    assert!(facts.ram_bytes.is_some_and(|b| b > 0));
    #[cfg(unix)]
    assert!(facts.disk_total_bytes.is_some_and(|t| t >= facts.disk_free_bytes.unwrap()));
    let json = cli("machine", true, Path::new("/"));
    assert!(json.contains("\"vcpus\""), "{json}");
    let card = cli("capabilities", false, Path::new("/"));
    assert!(card.contains("<where-you-are>") && card.contains("Details:"), "{card}");
}

/// The card for a local and a Cloud chat with every tool server on, as the PR shows them
/// (`cargo test -p acpmux --lib example_cards -- --nocapture`).
#[test]
fn example_cards() {
    let all: Vec<String> =
        CAPABILITIES.iter().filter_map(|c| c.server).map(str::to_owned).collect();
    let local = MachineFacts { place: Place::Local, ..facts(Place::Local) };
    let local_caps: Vec<String> = all
        .iter()
        .filter(|s| *s != agent_tools::DESKTOP_LEASE_SERVER && *s != crate::github_mcp::SERVER_NAME)
        .cloned()
        .collect();
    let cloud_caps: Vec<String> = local_caps
        .iter()
        .filter(|s| *s != crate::computer_use::mcp::SERVER_NAME)
        .cloned()
        .chain([crate::github_mcp::SERVER_NAME.to_owned()])
        .collect();
    println!("--- local ---\n{}", render(&local, &enabled(Place::Local, &local_caps)));
    println!(
        "--- cloud ---\n{}",
        render(&facts(Place::Cloud), &enabled(Place::Cloud, &cloud_caps))
    );
}
