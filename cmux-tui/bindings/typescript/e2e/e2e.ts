import { CmuxClient, CmuxCommandError, CmuxTimeoutError, Tree } from "../src/index.js";

async function main(): Promise<void> {
  const socketPath = process.env.CMUX_TUI_SOCKET || process.env.CMUX_MUX_SOCKET;
  if (!socketPath) throw new Error("CMUX_TUI_SOCKET is required");

  const marker = `CMUX_TS_E2E_${process.pid}_${Date.now()}`;
  const later = `${marker}_ATTACH`;
  const client = new CmuxClient({ socketPath, timeoutMs: 5000 });
  try {
    const identify = await client.identify();
    assert(identify.app === "cmux-tui", `unexpected app ${identify.app}`);
    assert(identify.protocol >= 5 && identify.protocol <= 9, `unsupported protocol ${identify.protocol}`);

    const created = await client.newWorkspace({ name: marker, cols: 80, rows: 24 });
    await client.send(created.surface, { text: `printf '${marker}\\n'\r` });
    await waitForMarker(client, created.surface, marker);
    const screen = await client.readScreen(created.surface);
    assert(screen.text.includes(marker), "marker missing from read-screen");

    const tree = await client.listWorkspaces();
    const workspaceId = findWorkspaceForSurface(tree, created.surface);
    assert(workspaceId !== undefined, "new workspace not found");
    const paneId = findPaneForSurface(tree, created.surface);
    assert(paneId !== undefined, "new pane not found");

    await client.split(paneId, "right");
    const splitTree = await client.listWorkspaces();
    const layout = findLayoutForSurface(splitTree, created.surface);
    assert(layout?.type === "split", "split layout not found");
    if (identify.protocol >= 8) {
      assert(layout.split !== undefined, "protocol v8 split id missing");
      const splitId = layout.split;
      await client.setSplitRatio(splitId, 0.65);
      const resizedLayout = findLayoutForSurface(await client.listWorkspaces(), created.surface);
      assert(resizedLayout?.type === "split", "resized split layout not found");
      assert(resizedLayout.split === splitId, "split id changed after ratio update");
      assert(Math.abs(resizedLayout.ratio - 0.65) < 0.0001, "split ratio did not update");
    }
    await client.setRatio(paneId, "right", 0.55);

    await client.renameSurface(created.surface, `${marker}-renamed`);
    const events = await client.subscribe();
    const title = `${marker}-title`;
    await client.send(created.surface, { text: `printf '\\033]2;${title}\\007'; sleep 5\r` });
    const titleChanged = await nextTitleChanged(events, created.surface, title, 3000);
    assert(titleChanged.title === title, `bad title event ${JSON.stringify(titleChanged)}`);
    await client.send(created.surface, { text: "\x03" });
    await client.resizeSurface(created.surface, 100, 31);
    const resized = await nextSurfaceResized(events, created.surface, 1000);
    assert(resized.cols === 100 && resized.rows === 31, `bad resize event ${JSON.stringify(resized)}`);
    await client.resizeSurface(created.surface, 100, 31);
    const duplicate = await nextSurfaceResized(events, created.surface, 500).catch((err) => {
      if (err instanceof CmuxTimeoutError) return null;
      throw err;
    });
    assert(duplicate === null, "same-size resize emitted surface-resized");
    events.close();

    const attach = await client.attachSurface(created.surface, { cols: 100, rows: 31 });
    const first = await attach.next(1000);
    assert(first.event === "vt-state", `first attach event was ${first.event}`);
    await client.send(created.surface, { text: `printf '${later}\\n'\r` });
    const output = await nextAttachOutput(attach, 3000);
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

function findPaneForSurface(tree: Tree, surface: number): number | undefined {
  for (const workspace of tree.workspaces) {
    for (const screen of workspace.screens) {
      for (const pane of screen.panes) {
        if ("tabs" in pane && pane.tabs?.some((tab) => tab.surface === surface)) return pane.id;
      }
    }
  }
  return undefined;
}

function findLayoutForSurface(tree: Tree, surface: number) {
  for (const workspace of tree.workspaces) {
    for (const screen of workspace.screens) {
      if (screen.panes.some((pane) => "tabs" in pane && pane.tabs.some((tab) => tab.surface === surface))) {
        return screen.layout;
      }
    }
  }
  return undefined;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
