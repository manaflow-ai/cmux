use cmux_client::{
    AttachBuilder, ClientConfig, CloseSurfaceRequest, CmuxClient, CmuxError, Event, Result,
};
use std::env;
use std::thread;
use std::time::{Duration, Instant};

fn main() -> Result<()> {
    let socket = env::var("CMUX_TUI_SOCKET")
        .or_else(|_| env::var("CMUX_MUX_SOCKET"))
        .map_err(|_| CmuxError::Connection("CMUX_TUI_SOCKET is required".to_string()))?;
    let mut client = CmuxClient::connect(ClientConfig::from_socket_path(socket))?;
    let identify = client.identify_server()?;
    assert_eq!(identify.protocol, 10);

    let marker = format!("CMUX_RUST_E2E_{}", std::process::id());
    let created = client.new_workspace_simple(Some(&marker), Some((80, 24)))?;
    client.send_text(created.surface, format!("printf '{marker}\\n'\r"))?;

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let screen = client.read_surface(created.surface)?;
        if screen.text.contains(&marker) {
            break;
        }
        assert!(Instant::now() < deadline, "marker missing from screen: {:?}", screen.text);
        thread::sleep(Duration::from_millis(50));
    }

    let mut attach =
        AttachBuilder::bytes(created.surface).initial_size(80, 24).open(&mut client)?;
    assert!(matches!(attach.recv()?, Event::VtState(_)));

    client.close_surface(CloseSurfaceRequest { surface: created.surface })?;
    loop {
        if matches!(attach.recv()?, Event::Detached(_)) {
            break;
        }
    }
    Ok(())
}
