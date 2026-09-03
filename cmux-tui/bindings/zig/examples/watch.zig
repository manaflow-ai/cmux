const std = @import("std");
const cmux = @import("cmux_tui");

fn requirePublicDecl(
    comptime Container: type,
    comptime name: []const u8,
) void {
    if (!@hasDecl(Container, name)) {
        @compileError(std.fmt.comptimePrint(
            "{s} must expose {s}",
            .{ @typeName(Container), name },
        ));
    }
}

fn rejectPublicDecl(
    comptime Container: type,
    comptime name: []const u8,
) void {
    if (@hasDecl(Container, name)) {
        @compileError(std.fmt.comptimePrint(
            "{s} must not expose {s}",
            .{ @typeName(Container), name },
        ));
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var client = try cmux.Client.connect(allocator, .{});
    defer client.deinit();

    var machines = try client.machines();
    defer machines.deinit();
    for (machines.items) |machine| {
        std.debug.print(
            "{s}\t{s}\t{s}\n",
            .{
                machine.id.slice(),
                machine.name,
                machine.status.wireName(),
            },
        );
    }
}

test "package consumer imports handwritten root and generated raw module" {
    comptime {
        requirePublicDecl(cmux.Machine, "listSessions");
        rejectPublicDecl(cmux.Machine, "close");
        rejectPublicDecl(cmux.Machine, "rename");
        requirePublicDecl(cmux.Session, "createWorkspace");
        requirePublicDecl(cmux.Session, "terminal");
        rejectPublicDecl(cmux.Session, "navigate");
        requirePublicDecl(cmux.Workspace, "run");
        rejectPublicDecl(cmux.Workspace, "terminal");
        rejectPublicDecl(cmux.Workspace, "sendKeys");
        requirePublicDecl(cmux.Screen, "undoLayout");
        rejectPublicDecl(cmux.Screen, "run");
        requirePublicDecl(cmux.Pane, "splitPane");
        rejectPublicDecl(cmux.Pane, "navigate");
        requirePublicDecl(cmux.Tab, "moveTab");
        rejectPublicDecl(cmux.Tab, "run");
        requirePublicDecl(cmux.Terminal, "waitForExit");
        rejectPublicDecl(cmux.Terminal, "resizeTerminalViewer");
        rejectPublicDecl(cmux.Terminal, "navigate");
        requirePublicDecl(cmux.Browser, "navigate");
        rejectPublicDecl(cmux.Browser, "readScreen");
        rejectPublicDecl(cmux.PairingRequest, "refresh");
        requirePublicDecl(
            cmux.TerminalAttachmentStream,
            "resizeTerminalViewer",
        );
        rejectPublicDecl(
            cmux.TerminalAttachmentStream,
            "resizeBrowserViewer",
        );
        requirePublicDecl(
            cmux.BrowserAttachmentStream,
            "resizeBrowserViewer",
        );
        rejectPublicDecl(
            cmux.BrowserAttachmentStream,
            "resizeTerminalViewer",
        );
        rejectPublicDecl(
            cmux.SessionEventStream,
            "resizeTerminalViewer",
        );
        rejectPublicDecl(cmux, "Notification");
        rejectPublicDecl(cmux, "Agent");
    }

    const workspace = try cmux.WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );
    var selector = cmux.Selector(cmux.WorkspaceId){ .name = "current" };
    const encoded = try selector.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("name:current", encoded);
    try std.testing.expectEqualStrings(
        "ws_0123456789abcdef0123456789abcdef",
        workspace.slice(),
    );
    const pointer_frame_seq = std.math.maxInt(u64);
    const mouse = cmux.BrowserMouseOptions{
        .kind = .move,
        .x_px = 12,
        .y_px = 34,
        .pointer_frame_seq = pointer_frame_seq,
    };
    const wheel = cmux.BrowserWheelOptions{
        .delta_x = 0,
        .delta_y = 1,
        .pointer_frame_seq = pointer_frame_seq,
    };
    try std.testing.expectEqual(
        pointer_frame_seq,
        mouse.pointer_frame_seq,
    );
    try std.testing.expectEqual(
        pointer_frame_seq,
        wheel.pointer_frame_seq,
    );
    try std.testing.expectEqual(
        @as(usize, 104),
        cmux.raw.protocol.command_count,
    );
    try std.testing.expectEqual(
        @as(usize, 47),
        cmux.raw.protocol.event_count,
    );
    try std.testing.expect(
        @hasDecl(cmux.Client, "listMachines"),
    );
    try std.testing.expect(
        @hasDecl(cmux.Machine, "listSessions"),
    );
    try std.testing.expect(
        @hasDecl(cmux.Session, "listWorkspaces"),
    );
    try std.testing.expect(@hasDecl(cmux.Terminal, "readScreen"));
    try std.testing.expect(@hasDecl(cmux.Terminal, "readState"));
    try std.testing.expect(@hasDecl(cmux.Terminal, "readHistory"));
    try std.testing.expect(@hasDecl(cmux.Terminal, "processInfo"));
    try std.testing.expect(@hasDecl(cmux, "TerminalScreenResult"));
    try std.testing.expect(@hasDecl(cmux, "UndoLayoutOptions"));
    try std.testing.expect(
        @hasDecl(cmux, "MutationTransportUncertain"),
    );
    try std.testing.expect(
        @hasDecl(cmux.Client, "takeMutationTransportUncertain"),
    );
    try std.testing.expect(!@hasDecl(cmux, "MutationResult"));
    try std.testing.expect(!@hasDecl(cmux, "OwnedResult"));

    // Handle construction stores selectors and routes without touching the
    // client, so an external consumer can compose a route before connecting.
    var offline_client: cmux.Client = undefined;
    const terminal = offline_client
        .machine(.current)
        .session(.{ .name = "main" })
        .workspace(.{ .name = "sdk" })
        .screen(.current)
        .pane(.current)
        .tab(.current)
        .terminal(.{ .name = "shell" });
    try std.testing.expect(terminal.id() == null);

    const terminal_id = try cmux.TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );
    const grant = try cmux.RendererGrant.init(std.testing.allocator, .{
        .endpoint = "/tmp/cmux-renderer.sock",
        .terminal_id = terminal_id,
        .token = .{ .bytes = "secret" },
        .rights = &.{ "read", "input" },
        .ttl_ms = 5_000,
    });
    defer grant.deinit();
    try std.testing.expectEqualStrings(
        "/tmp/cmux-renderer.sock",
        grant.endpoint(),
    );
}
