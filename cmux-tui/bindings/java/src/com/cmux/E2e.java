package com.cmux;

import java.time.Duration;

public final class E2e {
    public static void main(String[] args) throws Exception {
        String socket = socketFromEnv();
        if (socket == null || socket.isBlank()) {
            throw new IllegalStateException("CMUX_TUI_SOCKET is required");
        }
        String marker = "CMUX_JAVA_E2E_" + ProcessHandle.current().pid() + "_" + System.nanoTime();
        String later = marker + "_ATTACH";
        try (CmuxClient client = CmuxClient.builder().socketPath(socket).build()) {
            IdentifyResult identify = client.identify();
            check("cmux-tui".equals(identify.app()), "unexpected app " + identify.app());
            check(identify.protocol() >= 5 && identify.protocol() <= 9, "unsupported protocol " + identify.protocol());
            SurfaceResult created = client.newWorkspace(NewWorkspaceRequest.builder().name(marker).cols(80).rows(24).build());
            client.send(created.surface(), "printf '" + marker + "\\n'\r");
            waitForMarker(client, created.surface(), marker);
            check(client.readScreen(created.surface()).text().contains(marker), "marker missing from read-screen");
            long workspace = findWorkspaceForSurface(client.listWorkspaces(), created.surface());
            client.renameSurface(created.surface(), marker + "-renamed");
            try (CmuxClient.CmuxStream events = client.subscribe()) {
                client.resizeSurface(created.surface(), 100, 31);
                SurfaceResizedEvent resized = nextResized(events, created.surface(), Duration.ofSeconds(1));
                check(resized.cols() == 100 && resized.rows() == 31, "bad resize event");
                client.resizeSurface(created.surface(), 100, 31);
                boolean gotDuplicate = false;
                try {
                    nextResized(events, created.surface(), Duration.ofMillis(500));
                    gotDuplicate = true;
                } catch (CmuxTimeoutException expectedTimeout) {
                    // no event is the expected result
                }
                check(!gotDuplicate, "same-size resize emitted surface-resized");
            }
            try (CmuxClient.CmuxStream attach = client.attachSurface(created.surface(), 100, 31)) {
                CmuxEvent first = attach.next(Duration.ofSeconds(1));
                check(first instanceof VtStateEvent, "first attach event was " + first.event());
                client.send(created.surface(), "printf '" + later + "\\n'\r");
                nextAttachOutput(attach, Duration.ofSeconds(3));
            }
            client.closeWorkspace(workspace);
            check(findWorkspaceForSurface(client.listWorkspaces(), created.surface()) == -1, "closed workspace still present");
            try {
                client.readScreen(created.surface());
                throw new AssertionError("read-screen on closed surface unexpectedly succeeded");
            } catch (CmuxCommandException err) {
                check(!err.serverMessage().isBlank(), "server error string was not preserved");
            }
        }
    }

    private static String socketFromEnv() {
        String socket = System.getenv("CMUX_TUI_SOCKET");
        if (socket != null && !socket.isBlank()) {
            return socket;
        }
        return System.getenv("CMUX_MUX_SOCKET");
    }

    private static void waitForMarker(CmuxClient client, long surface, String marker) throws Exception {
        long deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos();
        String last = "";
        while (System.nanoTime() < deadline) {
            last = client.readScreen(surface).text();
            if (last.contains(marker)) {
                return;
            }
            Thread.sleep(50);
        }
        throw new AssertionError("marker not found; last screen: " + last);
    }

    private static SurfaceResizedEvent nextResized(CmuxClient.CmuxStream stream, long surface, Duration timeout) throws Exception {
        long deadline = System.nanoTime() + timeout.toNanos();
        while (System.nanoTime() < deadline) {
            CmuxEvent event = stream.next(Duration.ofNanos(deadline - System.nanoTime()));
            if (event instanceof SurfaceResizedEvent resized && resized.surface() == surface) {
                return resized;
            }
        }
        throw new CmuxTimeoutException("surface-resized not observed");
    }

    private static void nextAttachOutput(CmuxClient.CmuxStream stream, Duration timeout) throws Exception {
        long deadline = System.nanoTime() + timeout.toNanos();
        while (System.nanoTime() < deadline) {
            CmuxEvent event = stream.next(Duration.ofNanos(deadline - System.nanoTime()));
            if (event instanceof OutputEvent || event instanceof ResizedEvent) {
                return;
            }
        }
        throw new CmuxTimeoutException("attach output not observed");
    }

    private static long findWorkspaceForSurface(Tree tree, long surface) {
        for (Workspace workspace : tree.workspaces()) {
            for (Screen screen : workspace.screens()) {
                for (Pane pane : screen.panes()) {
                    for (Tab tab : pane.tabs()) {
                        if (tab.surface() == surface) {
                            return workspace.id();
                        }
                    }
                }
            }
        }
        return -1;
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
