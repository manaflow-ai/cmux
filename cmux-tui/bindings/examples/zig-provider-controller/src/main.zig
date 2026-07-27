const std = @import("std");
const provider = @import("provider_controller");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) return usage();

    const socket_path = args[1];
    const authority = std.process.getEnvVarOwned(
        allocator,
        "CMUX_PROVIDER_AUTHORITY",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.MissingProviderAuthority,
        else => return err,
    };
    defer {
        @memset(authority, 0);
        allocator.free(authority);
    }

    var controller = try provider.ProviderController.connect(allocator, .{
        .socket_path = socket_path,
        .authority = authority,
    });
    defer controller.deinit();
    try controller.initialize();

    const command = args[2];
    if (std.mem.eql(u8, command, "inspect")) {
        try printTopology(&controller);
        return;
    }
    if (std.mem.eql(u8, command, "create")) {
        if (args.len != 6) return usage();
        const mutation = try controller.createWorkspace(
            try controller.workspaceRevision(),
            args[3],
            args[4],
            args[5],
        );
        std.debug.print(
            "created workspace={d} revision={d} replayed={}\n",
            .{
                mutation.workspace,
                mutation.workspace_revision,
                mutation.replayed,
            },
        );
        return;
    }
    if (std.mem.eql(u8, command, "rename")) {
        if (args.len != 6) return usage();
        const mutation = try controller.renameWorkspace(
            try controller.workspaceRevision(),
            try std.fmt.parseInt(u64, args[3], 10),
            args[4],
            args[5],
        );
        std.debug.print(
            "renamed workspace={d} revision={d}\n",
            .{ mutation.workspace, mutation.workspace_revision },
        );
        return;
    }
    if (std.mem.eql(u8, command, "close")) {
        if (args.len != 5) return usage();
        const mutation = try controller.closeWorkspace(
            try controller.workspaceRevision(),
            try std.fmt.parseInt(u64, args[3], 10),
            args[4],
        );
        std.debug.print(
            "closed workspace={d} revision={d}\n",
            .{ mutation.workspace, mutation.workspace_revision },
        );
        return;
    }
    return usage();
}

fn printTopology(controller: *const provider.ProviderController) !void {
    std.debug.print(
        "registry={s} generation={s} revision={d}\n",
        .{
            try controller.registryId(),
            try controller.generationId(),
            try controller.workspaceRevision(),
        },
    );
    for (try controller.workspaces()) |workspace| {
        std.debug.print(
            "workspace={d} key={s} active={} name={s}\n",
            .{ workspace.id, workspace.key, workspace.active, workspace.name },
        );
    }
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  cmux-zig-provider-controller <socket> inspect
        \\  cmux-zig-provider-controller <socket> create <name> <uuid-key> <mutation-id>
        \\  cmux-zig-provider-controller <socket> rename <workspace-id> <key> <name>
        \\  cmux-zig-provider-controller <socket> close <workspace-id> <key>
        \\
        \\CMUX_PROVIDER_AUTHORITY must contain the pre-provisioned provider authority.
        \\
    , .{});
    return error.InvalidArguments;
}
