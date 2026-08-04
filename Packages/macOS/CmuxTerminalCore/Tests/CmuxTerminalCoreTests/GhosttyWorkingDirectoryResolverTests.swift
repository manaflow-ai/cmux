import CmuxTerminalCore
import Testing

@Suite struct GhosttyWorkingDirectoryResolverTests {
    private let home = "/Users/tester"
    private let processDirectory = "/Applications/cmux.app"

    @Test(arguments: [nil, "", "  ", "relative/path"] as [String?])
    func absentOrInvalidValuesFallBackToHome(_ configuredValue: String?) {
        #expect(resolve(configuredValue) == home)
    }

    @Test func homeUsesCurrentUserHomeDirectory() {
        #expect(resolve("home") == home)
    }

    @Test func inheritUsesProcessWorkingDirectory() {
        #expect(resolve("inherit") == processDirectory)
    }

    @Test func tildePathExpandsAgainstCurrentUserHomeDirectory() {
        #expect(resolve("~/Projects/cmux") == "/Users/tester/Projects/cmux")
    }

    @Test func absolutePathPassesThrough() {
        #expect(resolve("/Volumes/Work/cmux") == "/Volumes/Work/cmux")
    }

    @Test func invalidProcessDirectoryFallsBackToHome() {
        #expect(
            GhosttyWorkingDirectoryResolver(
                homeDirectory: home,
                processWorkingDirectory: "relative/path"
            ).resolve(configuredValue: "inherit") == home
        )
    }

    private func resolve(_ configuredValue: String?) -> String {
        GhosttyWorkingDirectoryResolver(
            homeDirectory: home,
            processWorkingDirectory: processDirectory
        ).resolve(configuredValue: configuredValue)
    }
}
