import PackagePlugin

@main
struct DeviceGlyphGeneratorPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let root = context.package.directory
        let repo = root.appending("../../../")
        let script = repo.appending("scripts/cmux-next/gen-device-glyph-swift.py")
        let input = repo.appending("webviews/src/ui/deviceGlyphKinds.json")
        let output = context.pluginWorkDirectory.appending("DeviceGlyphKind.swift")
        return [.buildCommand(
            displayName: "Generate device-kind glyph table",
            executable: Path("/usr/bin/python3"),
            arguments: [script, input, output],
            inputFiles: [script, input],
            outputFiles: [output]
        )]
    }
}
