const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmux_tui = b.addModule("cmux_tui", .{
        .root_source_file = b.path("../../zig/src/cmux.zig"),
        .target = target,
        .optimize = optimize,
    });

    const provider_controller = b.addModule("provider_controller", .{
        .root_source_file = b.path("src/controller.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider_controller.addImport("cmux_tui", cmux_tui);

    const executable_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    executable_module.addImport("provider_controller", provider_controller);

    const executable = b.addExecutable(.{
        .name = "cmux-zig-provider-controller",
        .root_module = executable_module,
        .version = std.SemanticVersion.parse("0.1.0") catch unreachable,
    });
    b.installArtifact(executable);

    const run_executable = b.addRunArtifact(executable);
    if (b.args) |args| run_executable.addArgs(args);
    const run_step = b.step("run", "Run the provider controller");
    run_step.dependOn(&run_executable.step);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("tests/fake_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_module.addImport("cmux_tui", cmux_tui);
    tests_module.addImport("provider_controller", provider_controller);
    const tests = b.addTest(.{
        .name = "cmux-zig-provider-controller-tests",
        .root_module = tests_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run deterministic fake Unix server tests");
    test_step.dependOn(&run_tests.step);
}
