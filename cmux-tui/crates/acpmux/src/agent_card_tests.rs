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

fn no_forks() -> can_get::CanGet {
    can_get::CanGet::with_forks(false)
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
    let text = render(&facts(Place::Cloud), &enabled(Place::Cloud, &all), &no_forks());
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
    let auto = render(&facts(Place::AutoCloud), &enabled(Place::AutoCloud, &all), &no_forks());
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
    let local_card = render(&facts(Place::Local), &enabled(Place::Local, &[]), &no_forks());
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
    let stale = render(&facts(Place::Cloud), &[], &no_forks());
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
    println!("--- local ---\n{}", render(&local, &enabled(Place::Local, &local_caps), &no_forks()));
    println!(
        "--- cloud ---\n{}",
        render(&facts(Place::Cloud), &enabled(Place::Cloud, &cloud_caps), &no_forks())
    );
}

/// Leo: "but what if we want even more than the 32vcpu machines? how can an agent know/ask for
/// more capacity?" The card says the largest machine, fan-out past it, that there is no Mac or
/// GPU tier, a price and a time for each, and how to ask, above this machine's numbers.
#[test]
fn the_card_says_what_the_agent_can_get_and_how_to_ask() {
    let text = render(&facts(Place::Cloud), &[], &no_forks());
    assert!(text.contains("up to 32 vCPU, 64 GB RAM, 256 GB disk on Max"), "{text}");
    assert!(text.contains("(Pro and Team: 8 vCPU, 16 GB, 128 GB)"), "{text}");
    assert!(text.contains("about $2.12/h at the top, ready in about 12 s"), "{text}");
    assert!(text.contains("up to 5 Cloud machines at once (160 vCPU on Max)"), "{text}");
    assert!(text.contains("No Mac or GPU Cloud machines yet."), "{text}");
    assert!(text.contains("`cmux machine request --vcpu N --mem M [--fanout K] [--kind mac|gpu] --for \"why\" --until ...`"), "{text}");
    assert!(text.contains("is not on this build yet"), "{text}");
    assert!(!text.contains("start_session, worktree: true"), "no forks here: {text}");
    let can = text.find("What you can get").unwrap();
    assert!(can < text.find("This machine now:").unwrap(), "{text}");
    let forks = render(&facts(Place::Cloud), &[], &can_get::CanGet::with_forks(true));
    assert!(forks.contains("gets its own fork of this machine in about 37 s"), "{forks}");
}

/// The ladder is `web/services/vms/images/sizes.ts`'s and the prices are the turn-cost list
/// rates; `cmux capabilities` prints both, and its JSON carries them.
#[test]
fn capabilities_lists_every_size_with_its_price() {
    let more = no_forks();
    let shapes: Vec<_> =
        more.sizes.iter().map(|s| (s.shape.name, s.shape.vcpus, s.shape.memory_gib)).collect();
    assert_eq!(
        shapes,
        vec![
            ("sm", 2, 4),
            ("md", 4, 8),
            ("lg", 8, 16),
            ("lgx", 12, 24),
            ("xl", 16, 32),
            ("2xl", 32, 64)
        ]
    );
    let md = &more.sizes[1];
    // 4 x 0.04032 + 8 x 0.0129 = 0.26 (machineCost.ts: "A 4 vCPU / 8 GB machine is about $0.26 an hour").
    assert_eq!(md.usd_per_hour, 0.26);
    assert_eq!(more.largest.shape.name, "2xl");
    assert_eq!(more.largest_below_max.shape.name, "lg");
    let below: Vec<_> = can_get::LADDER.iter().filter(|s| s.plan != "max").collect();
    assert_eq!(below.last().copied(), Some(&can_get::LARGEST_BELOW_MAX));
    let table = more.table();
    assert!(
        table.contains("- 2xl: 32 vCPU, 64 GB RAM, 128 GB disk to start, max+, $2.12/h"),
        "{table}"
    );
    let text = cli("capabilities", false, Path::new("/"));
    assert!(text.contains("Cloud machine sizes") && text.contains("What you can get"), "{text}");
    let json: serde_json::Value =
        serde_json::from_str(&cli("capabilities", true, Path::new("/"))).unwrap();
    assert_eq!(json["can_get"]["largest"]["vcpus"], 32);
    assert_eq!(json["can_get"]["gpu"]["available"], false);
    assert_eq!(json["can_get"]["request"]["on_this_build"], false);
    assert_eq!(json["can_get"]["sizes"].as_array().unwrap().len(), 6);
}

/// The Duress number: the card's bytes per turn without and with the "what you can get" part.
#[test]
fn card_bytes_per_turn() {
    let all: Vec<String> =
        CAPABILITIES.iter().filter_map(|c| c.server).map(str::to_owned).collect();
    for place in [Place::Local, Place::Cloud] {
        let caps = enabled(place, &all);
        let with = render(&facts(place), &caps, &no_forks());
        let without = with.replace(&no_forks().lines(), "");
        let forks = render(&facts(place), &caps, &can_get::CanGet::with_forks(true));
        println!(
            "{place:?}: {} B without, {} B with ({} with forks), +{} B",
            without.len(),
            with.len(),
            forks.len(),
            with.len() - without.len()
        );
        assert!(with.len() - without.len() < 900, "the part stays short");
    }
}
