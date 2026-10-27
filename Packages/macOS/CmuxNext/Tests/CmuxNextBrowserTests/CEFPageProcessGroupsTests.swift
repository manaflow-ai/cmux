@testable import CmuxNextBrowser
import Foundation
import Testing

/// First-party pages reach the fork's renderer groups (p13-webui-012) only through the optional
/// export `cmux_shim_page_scheme_set_group`: a fork without it still loads and gets no call, and a
/// table made with the `pageProcessGroups` feature off names no group, so it makes no call either.
/// A `solo` or `secrets` page names no group in the app's table (FirstPartyPageSchemes), so it makes
/// no call and keeps one process per origin. Against a spy shim.
@MainActor @Suite(.serialized) struct CEFPageProcessGroupsTests {
    private static let root = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/pages/x")

    private static func table(grouped: Bool) -> [String: CEFPageSchemes.Entry] {
        [
            "cmux.cloud": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", processGroup: grouped ? "privileged" : nil),
            "cmux.history": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", processGroup: grouped ? "privileged" : nil),
            "cmux.files": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", processGroup: grouped ? "viewer" : nil),
            "cmux.diff": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'", dynamicPrefixes: ["__patch"],
                                              entry: "diff-page.html"),
            "cmux.passwords": CEFPageSchemes.Entry(root: root, csp: "default-src 'self'"),
        ]
    }

    @Test func aForkWithoutTheExportLoadsAndGetsNoGroupCall() throws {
        GroupSpy.reset(exportsSetGroup: false)
        let library = try GroupSpy.library()
        #expect(library.pageSchemeSetGroup == nil, "dlsym found no export, so the shim must not have one")
        let refused = Self.add(Self.table(grouped: true), to: library)
        #expect(refused.isEmpty, "\(refused)")
        #expect(GroupSpy.added.sorted() == ["cmux.cloud", "cmux.diff", "cmux.files", "cmux.history", "cmux.passwords"])
        #expect(GroupSpy.groups.isEmpty, "\(GroupSpy.groups)")
    }

    @Test func aForkWithTheExportGetsEachPagesGroup() throws {
        GroupSpy.reset(exportsSetGroup: true)
        let library = try GroupSpy.library()
        #expect(library.pageSchemeSetGroup != nil)
        let refused = Self.add(Self.table(grouped: true), to: library)
        #expect(refused.isEmpty, "\(refused)")
        #expect(GroupSpy.groups == ["cmux.cloud": "privileged", "cmux.files": "viewer", "cmux.history": "privileged"])
        #expect(GroupSpy.groups["cmux.diff"] == nil && GroupSpy.groups["cmux.passwords"] == nil,
                "a solo or secrets page got a group key, so it would share a renderer: \(GroupSpy.groups)")
    }

    /// The feature off: the app's table names no group, so the fork gets no call even when it has the export.
    @Test func aTableWithNoGroupsMakesNoCall() throws {
        GroupSpy.reset(exportsSetGroup: true)
        let library = try GroupSpy.library()
        let refused = Self.add(Self.table(grouped: false), to: library)
        #expect(refused.isEmpty, "\(refused)")
        #expect(GroupSpy.added.count == 5)
        #expect(GroupSpy.groups.isEmpty, "\(GroupSpy.groups)")
    }

    @Test func theIDsTheForkRefusesAreReported() throws {
        GroupSpy.reset(exportsSetGroup: true)
        GroupSpy.refusedGroupIDs = ["cmux.files"]
        let library = try GroupSpy.library()
        let refused = Self.add(Self.table(grouped: true), to: library)
        #expect(refused == [.group("cmux.files")])
    }

    /// The page ids the shim refuses are reported in the call in process, before any group.
    @Test func thePagesTheShimRefusesAreReportedInTheCall() throws {
        GroupSpy.reset(exportsSetGroup: true)
        GroupSpy.refusedPageIDs = ["cmux.diff", "cmux.cloud"]
        let library = try GroupSpy.library()
        let refused = Self.add(Self.table(grouped: true), to: library)
        #expect(refused == [.page("cmux.cloud"), .page("cmux.diff")])
    }

    /// ``CEFPageSchemes/add(_:through:refused:)`` through an in-process runtime over `library`: every
    /// verdict is the call's own result, so every refusal is in by the time it returns.
    private static func add(_ table: [String: CEFPageSchemes.Entry], to library: CEFShimLibrary) -> [CEFPageSchemes.Refusal] {
        let runtime = CEFRuntime(shim: library, storage: HostRepliesHarness.storage())
        _ = Unmanaged.passRetained(runtime)
        var refused: [CEFPageSchemes.Refusal] = []
        CEFPageSchemes.add(table, through: runtime) { refused.append($0) }
        return refused
    }
}

/// The shim's page-scheme calls, recorded.
private nonisolated enum GroupSpy {
    nonisolated(unsafe) static var added: [String] = []
    nonisolated(unsafe) static var groups: [String: String] = [:]
    nonisolated(unsafe) static var refusedGroupIDs: Set<String> = []
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var refusedPageIDs: Set<String> = []
    nonisolated(unsafe) static var exportsSetGroup = false

    static func reset(exportsSetGroup exports: Bool) {
        added = []
        groups = [:]
        refusedGroupIDs = []
        refusedPageIDs = []
        exportsSetGroup = exports
    }

    /// The shim's answer to a page add: 0 for a refused id, after recording the call.
    static func page(_ id: UnsafePointer<CChar>?) -> Int32 {
        let id = id.map { String(cString: $0) } ?? ""
        added.append(id)
        return refusedPageIDs.contains(id) ? 0 : 1
    }

    static func library() throws -> CEFShimLibrary {
        let add: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { id, _, _ in
            GroupSpy.page(id)
        }
        let addDynamic: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                        UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { id, _, _, _, _ in
            GroupSpy.page(id)
        }
        let setGroup: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { id, group in
            let id = id.map { String(cString: $0) } ?? ""
            guard !GroupSpy.refusedGroupIDs.contains(id) else { return 0 }
            GroupSpy.groups[id] = group.map { String(cString: $0) } ?? ""
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            return switch name {
            case "cmux_shim_page_scheme_add_first_party": unsafeBitCast(add, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_page_scheme_add_first_party_dynamic": unsafeBitCast(addDynamic, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_page_scheme_set_group":
                GroupSpy.exportsSetGroup ? unsafeBitCast(setGroup, to: UnsafeMutableRawPointer.self) : nil
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
