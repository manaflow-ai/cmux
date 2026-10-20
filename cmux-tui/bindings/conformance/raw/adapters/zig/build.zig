const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmux_tui = b.addModule("cmux_tui", .{
        .root_source_file = b.path("../../../../zig/src/cmux.zig"),
        .target = target,
        .optimize = optimize,
    });
    const adapter = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.addImport("cmux_tui", cmux_tui);

    const executable = b.addExecutable(.{
        .name = "cmux-conformance-zig",
        .root_module = adapter,
    });
    b.installArtifact(executable);
}
