const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmux_tui = b.addModule("cmux_tui", .{
        .root_source_file = b.path("src/cmux.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The catalog's error codes, for the test that compares them with the
    // codes this SDK types. A package outside the cmux repository has no
    // catalog beside it; that test then skips.
    const catalog = b.addOptions();
    const error_codes = catalogErrorCodes(b);
    catalog.addOption(bool, "present", error_codes != null);
    catalog.addOption([]const []const u8, "error_codes", error_codes orelse &.{});
    cmux_tui.addOptions("resource_catalog", catalog);

    const unit_tests = b.addTest(.{
        .name = "cmux-tui-zig-tests",
        .root_module = cmux_tui,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step(
        "test",
        "Run codec, transport, lifecycle, stream, and API tests",
    );
    test_step.dependOn(&run_unit_tests.step);

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/watch.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("cmux_tui", cmux_tui);
    const example = b.addExecutable(.{
        .name = "cmux-tui-watch",
        .root_module = example_module,
        .version = std.SemanticVersion.parse("1.0.0") catch unreachable,
    });
    b.installArtifact(example);

    const example_tests = b.addTest(.{
        .name = "cmux-tui-zig-consumer-test",
        .root_module = example_module,
    });
    const run_example_tests = b.addRunArtifact(example_tests);
    test_step.dependOn(&run_example_tests.step);
}

fn catalogErrorCodes(b: *std.Build) ?[]const []const u8 {
    const path = "../../spec/resource-operations-v2.json";
    const text = b.build_root.handle.readFileAlloc(b.allocator, path, 64 << 20) catch |failure| switch (failure) {
        error.FileNotFound => return null,
        else => std.debug.panic("cannot read {s}: {s}", .{ path, @errorName(failure) }),
    };
    const document = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, text, .{}) catch |failure|
        std.debug.panic("{s} is not JSON: {s}", .{ path, @errorName(failure) });
    const errors = switch (document) {
        .object => |object| object.get("errors") orelse std.debug.panic("{s} has no errors", .{path}),
        else => std.debug.panic("{s} is not an object", .{path}),
    };
    const codes = switch (errors) {
        .object => |object| object.keys(),
        else => std.debug.panic("{s} errors is not an object", .{path}),
    };
    return codes;
}
