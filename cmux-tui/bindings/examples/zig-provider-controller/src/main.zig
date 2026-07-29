const std = @import("std");
const cmux = @import("cmux_tui");
const provider = @import("provider_controller");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 7) return usage();

    var controller = try provider.ProviderController.connect(allocator, .{
        .socket_path = args[1],
        .provider_scope_id = try cmux.ProviderScopeId.parse(args[2]),
        .session_id = try cmux.SessionId.parse(args[3]),
        .workspace_id = try cmux.WorkspaceId.parse(args[4]),
        .revision = try std.fmt.parseInt(u64, args[5], 10),
    });
    defer controller.deinit();

    const command = args[6];
    if (std.mem.eql(u8, command, "mark")) {
        if (args.len != 9) return usage();
        const managed = if (std.mem.eql(u8, args[7], "managed"))
            true
        else if (std.mem.eql(u8, args[7], "unmanaged"))
            false
        else
            return usage();
        const receipt = try controller.markManaged(managed, args[8]);
        printReceipt("marked", receipt);
        return;
    }
    if (std.mem.eql(u8, command, "rename")) {
        if (args.len != 9) return usage();
        const receipt = try controller.rename(args[7], args[8]);
        printReceipt("renamed", receipt);
        return;
    }
    if (std.mem.eql(u8, command, "clear-name")) {
        if (args.len != 8) return usage();
        const receipt = try controller.rename(null, args[7]);
        printReceipt("cleared-name", receipt);
        return;
    }
    if (std.mem.eql(u8, command, "close")) {
        if (args.len != 8) return usage();
        const receipt = try controller.closeWorkspace(args[7]);
        printReceipt("closed", receipt);
        return;
    }
    return usage();
}

fn printReceipt(action: []const u8, receipt: provider.Receipt) void {
    std.debug.print(
        "{s} revision={d} replayed={}\n",
        .{ action, receipt.revision, receipt.replayed },
    );
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  cmux-zig-provider-controller <socket> <provider-scope-id> <session-id> <workspace-id> <revision> mark <managed|unmanaged> <idempotency-key>
        \\  cmux-zig-provider-controller <socket> <provider-scope-id> <session-id> <workspace-id> <revision> rename <name> <idempotency-key>
        \\  cmux-zig-provider-controller <socket> <provider-scope-id> <session-id> <workspace-id> <revision> clear-name <idempotency-key>
        \\  cmux-zig-provider-controller <socket> <provider-scope-id> <session-id> <workspace-id> <revision> close <idempotency-key>
        \\
    , .{});
    return error.InvalidArguments;
}
