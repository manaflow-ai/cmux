use cmux_client::{
    ClientConfig, CmuxClient, CmuxError, Event, Result, TopologyCursor, TopologyOperation,
    TopologyResnapshotReason, TopologyStreamEvent, TopologySubscribeOutcome, Tree,
};
use std::env;
use std::thread;
use std::time::{Duration, Instant};

fn main() -> Result<()> {
    let socket = env::var("CMUX_TUI_SOCKET")
        .or_else(|_| env::var("CMUX_MUX_SOCKET"))
        .map_err(|_| CmuxError::Connection("CMUX_TUI_SOCKET is required".to_string()))?;
    let mut client = CmuxClient::connect(ClientConfig::from_socket_path(socket))?;
    let marker = format!("CMUX_RUST_E2E_{}_{}", std::process::id(), now_ms());
    let later = format!("{marker}_ATTACH");

    let identify = client.identify()?;
    assert!(identify.app == "cmux-tui", "unexpected app {}", identify.app);
    assert!((5..=8).contains(&identify.protocol), "unsupported protocol {}", identify.protocol);
    assert!(identify.supports_topology_v8(), "server omitted protocol-v8 topology capabilities");
    let identify_cursor = identify.topology_cursor().expect("identify omitted canonical cursor");
    let ping = client.ping()?;
    assert!(ping.ok, "ping reported false");
    assert_eq!(ping.session_id.as_ref(), identify.session_id.as_ref());
    assert_eq!(ping.daemon_instance_id.as_ref(), identify.daemon_instance_id.as_ref());
    assert_eq!(ping.topology_revision, identify.topology_revision);
    assert_eq!(ping.canonical_topology_revision, Some(identify_cursor.revision));

    let created = client.new_workspace(Some(&marker), Some(80), Some(24))?;
    client.send(created.surface, Some(&format!("printf '{marker}\\n'\r")), None)?;
    wait_for_marker(&mut client, created.surface, &marker)?;
    let screen = client.read_screen(created.surface)?;
    assert!(screen.text.contains(&marker), "marker missing from read-screen");

    let workspace_id = find_workspace_for_surface(&client.list_workspaces()?, created.surface)
        .expect("workspace not found");
    let snapshot = client.topology_snapshot()?;
    let canonical = snapshot
        .topology
        .workspaces
        .iter()
        .find(|workspace| {
            workspace.screens.iter().any(|screen| {
                screen
                    .panes
                    .iter()
                    .any(|pane| pane.tabs.iter().any(|tab| tab.id == created.surface))
            })
        })
        .expect("canonical workspace not found");
    assert_eq!(canonical.id, workspace_id);
    let mut topology = match client.subscribe_topology(snapshot.cursor())? {
        TopologySubscribeOutcome::Subscribed { info, stream } => {
            assert_eq!(info.from_revision, snapshot.revision);
            stream
        }
        TopologySubscribeOutcome::ResnapshotRequired(required) => {
            panic!("fresh snapshot required resnapshot: {:?}", required.reason)
        }
    };
    client.rename_workspace(workspace_id, &format!("{marker}-topology"))?;
    match topology.recv_timeout(Duration::from_secs(2))? {
        TopologyStreamEvent::Delta(delta) => {
            assert_eq!(delta.operation, TopologyOperation::WorkspaceRenamed);
            assert_eq!(delta.base_revision, snapshot.revision);
            assert_eq!(delta.revision, snapshot.revision + 1);
            assert_eq!(delta.replacement.workspaces[0].name, format!("{marker}-topology"));
        }
        TopologyStreamEvent::ResnapshotRequired(required) => {
            panic!("adjacent topology delta required resnapshot: {:?}", required.reason)
        }
    }
    topology.close();
    let stale = TopologyCursor {
        daemon_instance_id: "00000000-0000-0000-0000-000000000001".parse().unwrap(),
        session_id: snapshot.session_id.clone(),
        revision: snapshot.revision,
    };
    match client.subscribe_topology(stale)? {
        TopologySubscribeOutcome::ResnapshotRequired(required) => {
            assert_eq!(required.reason, TopologyResnapshotReason::StaleDaemon);
        }
        TopologySubscribeOutcome::Subscribed { mut stream, .. } => {
            stream.close();
            panic!("stale daemon cursor unexpectedly subscribed")
        }
    }
    client.rename_surface(created.surface, &format!("{marker}-renamed"))?;
    let mut events = client.subscribe()?;
    client.resize_surface(created.surface, 100, 31)?;
    let resized = next_resized(&mut events, created.surface, Duration::from_secs(1))?;
    assert_eq!((resized.0, resized.1), (100, 31));
    client.resize_surface(created.surface, 100, 31)?;
    match next_resized(&mut events, created.surface, Duration::from_millis(500)) {
        Err(CmuxError::Timeout(_)) => {}
        Ok(_) => panic!("same-size resize emitted surface-resized"),
        Err(err) => return Err(err),
    }

    let mut attach = client.attach_surface(created.surface)?;
    let first = attach.recv()?;
    assert!(matches!(first, Event::VtState(_)), "first attach event was {first:?}");
    client.send(created.surface, Some(&format!("printf '{later}\\n'\r")), None)?;
    next_attach_output(&mut attach, Duration::from_secs(3))?;

    client.close_workspace(workspace_id)?;
    let after_close = client.list_workspaces()?;
    assert!(find_workspace_for_surface(&after_close, created.surface).is_none());
    match client.read_screen(created.surface) {
        Err(CmuxError::Command { message, .. }) if !message.is_empty() => {}
        Ok(_) => panic!("read-screen on closed surface unexpectedly succeeded"),
        Err(err) => panic!("closed surface error was not command error: {err}"),
    }
    Ok(())
}

fn wait_for_marker(client: &mut CmuxClient, surface: u64, marker: &str) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut last = String::new();
    while Instant::now() < deadline {
        last = client.read_screen(surface)?.text;
        if last.contains(marker) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("marker not found; last screen: {last:?}");
}

fn next_resized(
    events: &mut cmux_client::CmuxStream,
    surface: u64,
    timeout: Duration,
) -> Result<(u16, u16)> {
    let deadline = Instant::now() + timeout;
    loop {
        if Instant::now() >= deadline {
            return Err(CmuxError::Timeout("surface-resized not observed".to_string()));
        }
        match events.recv_timeout(time_left(deadline))? {
            Event::SurfaceResized(event) if event.surface == surface => {
                return Ok((event.cols, event.rows));
            }
            _ => {}
        }
    }
}

fn next_attach_output(events: &mut cmux_client::CmuxStream, timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        if Instant::now() >= deadline {
            return Err(CmuxError::Timeout("attach output not observed".to_string()));
        }
        match events.recv_timeout(time_left(deadline))? {
            Event::Output(_) | Event::Resized(_) => return Ok(()),
            _ => {}
        }
    }
}

fn time_left(deadline: Instant) -> Duration {
    deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1))
}

fn find_workspace_for_surface(tree: &Tree, surface: u64) -> Option<u64> {
    for workspace in &tree.workspaces {
        for screen in &workspace.screens {
            for pane in &screen.panes {
                if pane.tabs.iter().any(|tab| tab.surface == surface) {
                    return Some(workspace.id);
                }
            }
        }
    }
    None
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock must be after unix epoch")
        .as_millis()
}
