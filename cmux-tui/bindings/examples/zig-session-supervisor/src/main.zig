const std = @import("std");
const supervisor_api = @import("session_supervisor");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 8 or !std.mem.eql(u8, args[6], "--")) {
        return usage();
    }

    const workspace_correlation = try key(
        allocator,
        args[5],
        "workspace",
    );
    defer allocator.free(workspace_correlation);
    const workspace_key_1 = try key(
        allocator,
        args[5],
        "workspace:1",
    );
    defer allocator.free(workspace_key_1);
    const workspace_key_2 = try key(
        allocator,
        args[5],
        "workspace:2",
    );
    defer allocator.free(workspace_key_2);
    const run_correlation = try key(allocator, args[5], "run");
    defer allocator.free(run_correlation);
    const run_key_1 = try key(allocator, args[5], "run:1");
    defer allocator.free(run_key_1);
    const run_key_2 = try key(allocator, args[5], "run:2");
    defer allocator.free(run_key_2);

    var supervisor = try supervisor_api.SessionSupervisor.connect(
        allocator,
        .{
            .socket_path = args[1],
            .machine_name = args[2],
            .session_name = args[3],
            .workspace_name = args[4],
        },
    );
    defer supervisor.deinit();

    const workspace = try supervisor.ensureWorkspace(
        workspace_correlation,
        .{ workspace_key_1, workspace_key_2 },
    );
    const run = try supervisor.runExact(
        args[7..],
        run_correlation,
        .{ run_key_1, run_key_2 },
    );
    const exit = try supervisor.waitUntilExit(
        run.path.terminal_id,
        5_000,
    );
    const event = try supervisor.observeOneEvent();

    std.debug.print(
        "workspace={s} created={} recovered={} revision={d}\n",
        .{
            workspace.id.slice(),
            workspace.created,
            workspace.recovered,
            workspace.revision,
        },
    );
    std.debug.print(
        "terminal={s} recovered={} revision={d}\n",
        .{
            run.path.terminal_id.slice(),
            run.recovered,
            run.revision,
        },
    );
    switch (exit.outcome) {
        .exit => |status| std.debug.print(
            "exit=status:{d} revision={d}\n",
            .{ status, exit.revision },
        ),
        .signal => |signal| std.debug.print(
            "exit=signal:{d} core_dumped={} revision={d}\n",
            .{
                signal.signal,
                signal.core_dumped,
                exit.revision,
            },
        ),
        .unknown => std.debug.print(
            "exit=unknown revision={d}\n",
            .{exit.revision},
        ),
    }
    std.debug.print(
        "event={s} sequence={d} cursor={?d} canceled_at={?d}\n",
        .{
            @tagName(event.kind),
            event.sequence,
            event.cursor_revision,
            event.canceled_at_revision,
        },
    );
}

fn key(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    suffix: []const u8,
) ![]u8 {
    const result = try std.fmt.allocPrint(
        allocator,
        "{s}:{s}",
        .{ prefix, suffix },
    );
    if (result.len > 128) {
        allocator.free(result);
        return error.KeyTooLong;
    }
    return result;
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  cmux-zig-session-supervisor <socket> <machine-name> <session-name> <workspace-name> <run-key> -- <command> [args...]
        \\
    , .{});
    return error.InvalidArguments;
}
