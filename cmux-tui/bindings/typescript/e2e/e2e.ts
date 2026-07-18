import {
  CmuxClient,
  CmuxCommandError,
  CmuxTimeoutError,
  Tree,
  UUID,
} from "../src/index.js";

async function main(): Promise<void> {
  const socketPath = process.env.CMUX_TUI_SOCKET || process.env.CMUX_MUX_SOCKET;
  if (!socketPath) throw new Error("CMUX_TUI_SOCKET is required");

  const marker = `CMUX_TS_E2E_${process.pid}_${Date.now()}`;
  const later = `${marker}_ATTACH`;
  const client = new CmuxClient({ socketPath, timeoutMs: 5000 });
  try {
    const identify = await client.identify();
    assert(identify.app === "cmux-tui", `unexpected app ${identify.app}`);
    assert(identify.protocol >= 5 && identify.protocol <= 8, `unsupported protocol ${identify.protocol}`);
    assert(
      identify.protocol >= 8 && identify.capabilities?.includes("topology-resume-v1"),
      "server omitted protocol-v8 topology capabilities",
    );
    assert(identify.canonical_topology_revision !== undefined, "identify omitted canonical revision");
    const ping = await client.ping();
    assert(ping.ok, "ping reported false");
    assert(ping.session_id === identify.session_id, "ping session authority changed");
    assert(ping.daemon_instance_id === identify.daemon_instance_id, "ping daemon authority changed");
    assert(ping.topology_revision === identify.topology_revision, "ping legacy revision changed");
    assert(
      ping.canonical_topology_revision === identify.canonical_topology_revision,
      "ping canonical revision changed",
    );

    const created = await client.newWorkspace({ name: marker, cols: 80, rows: 24 });
    await client.send(created.surface, { text: `printf '${marker}\\n'\r` });
    await waitForMarker(client, created.surface, marker);
    const screen = await client.readScreen(created.surface);
    assert(screen.text.includes(marker), "marker missing from read-screen");

    const tree = await client.listWorkspaces();
    const workspaceId = findWorkspaceForSurface(tree, created.surface);
    assert(workspaceId !== undefined, "new workspace not found");

    const snapshot = await client.topologySnapshot();
    const canonical = snapshot.topology.workspaces.find((workspace) =>
      workspace.screens.some((screen) =>
        screen.panes.some((pane) => pane.tabs.some((tab) => tab.id === created.surface))));
    assert(canonical?.id === workspaceId, "canonical topology omitted the new workspace");
    const topology = await client.subscribeTopology({
      daemon_instance_id: snapshot.daemon_instance_id,
      session_id: snapshot.session_id,
      revision: snapshot.revision,
    });
    assert(topology.status === "subscribed", `fresh snapshot required resnapshot: ${JSON.stringify(topology)}`);
    await client.renameWorkspace(workspaceId!, `${marker}-topology`);
    const topologyEvent = await stage("topology rename delta", topology.stream.next(2000));
    assert(topologyEvent.event === "topology-delta", `unexpected topology event ${JSON.stringify(topologyEvent)}`);
    if (topologyEvent.event === "topology-delta") {
      assert(topologyEvent.operation === "workspace-renamed", "wrong topology operation");
      assert(topologyEvent.base_revision === snapshot.revision, "wrong topology base revision");
      assert(topologyEvent.revision === snapshot.revision + 1, "wrong topology revision");
    }
    topology.stream.close();
    const stale = await client.subscribeTopology({
      daemon_instance_id: "00000000-0000-0000-0000-000000000001" as UUID,
      session_id: snapshot.session_id,
      revision: snapshot.revision,
    });
    assert(stale.status === "resnapshot-required", "stale daemon cursor unexpectedly subscribed");
    if (stale.status === "resnapshot-required") {
      assert(stale.reason === "stale-daemon", `wrong stale cursor reason ${stale.reason}`);
    }

    const events = await client.subscribe();
    const title = `${marker}-title`;
    await client.send(created.surface, { text: `printf '\\033]2;${title}\\007'; sleep 30\r` });
    const titleChanged = await stage(
      "OSC title event",
      nextTitleChanged(events, created.surface, title, 3000),
    );
    assert(titleChanged.title === title, `bad title event ${JSON.stringify(titleChanged)}`);
    await client.send(created.surface, { text: "\x03" });
    await client.resizeSurface(created.surface, 100, 31);
    const resized = await stage(
      "surface resize event",
      nextSurfaceResized(events, created.surface, 1000),
    );
    assert(resized.cols === 100 && resized.rows === 31, `bad resize event ${JSON.stringify(resized)}`);
    await client.resizeSurface(created.surface, 100, 31);
    const duplicate = await nextSurfaceResized(events, created.surface, 500).catch((err) => {
      if (err instanceof CmuxTimeoutError) return null;
      throw err;
    });
    assert(duplicate === null, "same-size resize emitted surface-resized");
    events.close();
    await client.renameSurface(created.surface, `${marker}-renamed`);

    const attach = await client.attachSurface(created.surface);
    const first = await stage("initial attach state", attach.next(1000));
    assert(first.event === "vt-state", `first attach event was ${first.event}`);
    await client.send(created.surface, { text: `printf '${later}\\n'\r` });
    const output = await stage("attach output", nextAttachOutput(attach, 3000));
    assert(output.event === "output" || output.event === "resized", "attach did not produce output/resized after vt-state");
    attach.close();

    await client.closeWorkspace(workspaceId!);
    const afterClose = await client.listWorkspaces();
    assert(findWorkspaceForSurface(afterClose, created.surface) === undefined, "closed workspace still present");
    try {
      await client.readScreen(created.surface);
      throw new Error("read-screen on closed surface unexpectedly succeeded");
    } catch (err) {
      assert(err instanceof CmuxCommandError, `closed surface error was not command error: ${err}`);
      assert(String(err.message).length > 0, "command error did not preserve server message");
    }
  } finally {
    await client.close().catch(() => undefined);
  }
}

async function nextTitleChanged(
  events: Awaited<ReturnType<CmuxClient["subscribe"]>>,
  surface: number,
  title: string,
  timeoutMs: number,
): Promise<{ event: "title-changed"; surface: number; title: string }> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = await events.next(Math.max(1, deadline - Date.now()));
    if (
      event.event === "title-changed" &&
      "surface" in event &&
      event.surface === surface &&
      "title" in event &&
      event.title === title
    ) {
      return { event: "title-changed", surface: event.surface, title: event.title };
    }
  }
  throw new Error("title-changed event not observed");
}

async function waitForMarker(client: CmuxClient, surface: number, marker: string): Promise<void> {
  const deadline = Date.now() + 5000;
  let last = "";
  while (Date.now() < deadline) {
    last = (await client.readScreen(surface)).text;
    if (last.includes(marker)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`marker not found; last screen: ${JSON.stringify(last)}`);
}

async function nextSurfaceResized(events: Awaited<ReturnType<CmuxClient["subscribe"]>>, surface: number, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new CmuxTimeoutError("surface-resized not observed");
    const event = await events.next(remaining);
    if (event.event === "surface-resized" && event.surface === surface) return event;
  }
}

async function nextAttachOutput(attach: Awaited<ReturnType<CmuxClient["attachSurface"]>>, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new CmuxTimeoutError("attach output not observed");
    const event = await attach.next(remaining);
    if (event.event === "output" || event.event === "resized") return event;
  }
}

function findWorkspaceForSurface(tree: Tree, surface: number): number | undefined {
  for (const workspace of tree.workspaces) {
    for (const screen of workspace.screens) {
      for (const pane of screen.panes) {
        if ("tabs" in pane && pane.tabs?.some((tab) => tab.surface === surface)) return workspace.id;
      }
    }
  }
  return undefined;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function stage<T>(name: string, operation: Promise<T>): Promise<T> {
  try {
    return await operation;
  } catch (error) {
    throw new Error(`${name}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
