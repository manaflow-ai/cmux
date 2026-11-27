import CmuxNextSettings
import Testing

/// `agents.trust.*`: folders and GitHub owners an agent may start in without the trust question;
/// bad values keep the defaults (or drop the entry) and say why.
struct TrustSettingsTests {
    private static func parse(_ members: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["agents": .object(["trust": .object(members)])]), validDensities: [], validMetrics: [])
    }

    @Test func defaultsWhenUnset() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        // Off, with nobody's folders or owners built in: the person names their own.
        #expect(snapshot.trust == TrustSettings())
        #expect(!snapshot.trust.autoTrust)
        #expect(snapshot.trust.projectRoots.isEmpty)
        #expect(snapshot.trust.ownOrgs.isEmpty)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsACustomList() {
        let snapshot = Self.parse([
            "autoTrust": .bool(true),
            "projectRoots": .array([.string("/Users/ada/Code"), .string("~/Work")]),
            "ownOrgs": .array([.string("ada")]),
        ])
        #expect(snapshot.trust.autoTrust)
        #expect(snapshot.trust.projectRoots == ["/Users/ada/Code", "~/Work"])
        #expect(snapshot.trust.ownOrgs == ["ada"])
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func emptyListsAreKept() {
        let snapshot = Self.parse(["projectRoots": .array([]), "ownOrgs": .array([])])
        #expect(snapshot.trust.projectRoots.isEmpty)
        #expect(snapshot.trust.ownOrgs.isEmpty)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func badEntriesAreDroppedAndReported() {
        let snapshot = Self.parse([
            "autoTrust": .string("yes"),
            "projectRoots": .array([.string("relative/dir"), .number(3), .string("/ok")]),
            "ownOrgs": .array([.string(""), .bool(true), .string("ada")]),
        ])
        #expect(!snapshot.trust.autoTrust)
        #expect(snapshot.trust.projectRoots == ["/ok"])
        #expect(snapshot.trust.ownOrgs == ["ada"])
        #expect(snapshot.diagnostics.filter { $0.path == "agents.trust.projectRoots" }.count == 2)
        #expect(snapshot.diagnostics.filter { $0.path == "agents.trust.ownOrgs" }.count == 2)
        #expect(snapshot.diagnostics.contains { $0.path == "agents.trust.autoTrust" })
    }

    @Test func notAnArrayKeepsTheDefaults() {
        let snapshot = Self.parse(["projectRoots": .string("/x"), "ownOrgs": .string("ada")])
        #expect(snapshot.trust.projectRoots.isEmpty)
        #expect(snapshot.trust.ownOrgs.isEmpty)
        #expect(snapshot.diagnostics.count == 2)
    }

    @Test func rowsAreInSettings() throws {
        let toggle = try #require(SettingsSchema.descriptor(for: ["agents", "trust", "autoTrust"]))
        let roots = try #require(SettingsSchema.descriptor(for: ["agents", "trust", "projectRoots"]))
        let orgs = try #require(SettingsSchema.descriptor(for: ["agents", "trust", "ownOrgs"]))
        #expect(toggle.kind == .toggle)
        #expect(roots.kind == .folderList)
        #expect(orgs.kind == .stringList)
    }
}
