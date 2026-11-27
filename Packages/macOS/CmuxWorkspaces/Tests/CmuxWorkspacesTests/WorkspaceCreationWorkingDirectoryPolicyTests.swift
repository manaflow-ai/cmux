import CmuxWorkspaces
import Testing

@Suite struct WorkspaceCreationWorkingDirectoryPolicyTests {
    @Test func explicitDirectoryWins() {
        #expect(
            resolve(explicit: "/explicit", inherited: "/inherited", enabled: true)
                == "/explicit"
        )
    }

    @Test func enabledInheritanceUsesSourceDirectory() {
        #expect(
            resolve(explicit: nil, inherited: "/inherited", enabled: true)
                == "/inherited"
        )
    }

    @Test func disabledInheritanceUsesConcreteDefault() {
        #expect(resolve(explicit: nil, inherited: "/inherited", enabled: false) == "/default")
    }

    @Test func missingInheritedDirectoryUsesConcreteDefault() {
        #expect(resolve(explicit: nil, inherited: nil, enabled: true) == "/default")
    }

    private func resolve(explicit: String?, inherited: String?, enabled: Bool) -> String {
        WorkspaceCreationWorkingDirectoryPolicy(inheritanceEnabled: enabled).resolve(
            explicitWorkingDirectory: explicit,
            inheritedWorkingDirectory: inherited,
            defaultWorkingDirectory: "/default"
        )
    }
}
