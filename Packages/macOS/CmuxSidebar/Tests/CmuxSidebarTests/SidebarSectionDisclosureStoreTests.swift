import Foundation
import Observation
import Testing

@testable import CmuxSidebar

@MainActor
@Suite struct SidebarSectionDisclosureStoreTests {
    @Test func restoresCollapsedSectionsAcrossStoreRecreation() throws {
        let suite = "cmux.sidebar-disclosure-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarSectionDisclosureStore(defaults: defaults)
        store.setCollapsed(true, providerID: "projects", sectionID: "collapsed")
        store.setCollapsed(true, providerID: "projects", sectionID: "expanded")
        store.setCollapsed(false, providerID: "projects", sectionID: "expanded")

        let restored = SidebarSectionDisclosureStore(defaults: defaults)
        #expect(restored.isCollapsed(providerID: "projects", sectionID: "collapsed"))
        #expect(!restored.isCollapsed(providerID: "projects", sectionID: "expanded"))
        #expect(!restored.isCollapsed(providerID: "projects", sectionID: "new"))
    }

    @Test func isolatesProvidersAndRetainsTemporarilyAbsentSections() throws {
        let suite = "cmux.sidebar-disclosure-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarSectionDisclosureStore(defaults: defaults)
        store.setCollapsed(true, providerID: "projects", sectionID: "missing")
        store.setCollapsed(true, providerID: "other", sectionID: "visible")
        store.setCollapsed(false, providerID: "other", sectionID: "missing")
        store.setCollapsed(true, providerID: "a:b", sectionID: "c")
        store.setCollapsed(true, providerID: "a", sectionID: "b:c")
        store.setCollapsed(false, providerID: "a:b", sectionID: "c")

        let restored = SidebarSectionDisclosureStore(defaults: defaults)
        #expect(restored.isCollapsed(providerID: "projects", sectionID: "missing"))
        #expect(!restored.isCollapsed(providerID: "other", sectionID: "missing"))
        #expect(!restored.isCollapsed(providerID: "projects", sectionID: "visible"))
        #expect(restored.isCollapsed(providerID: "other", sectionID: "visible"))
        #expect(!restored.isCollapsed(providerID: "a:b", sectionID: "c"))
        #expect(restored.isCollapsed(providerID: "a", sectionID: "b:c"))
    }

    @Test func boundsRememberedChoicesByEvictingOldestCollapse() throws {
        let suite = "cmux.sidebar-disclosure-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let limit = SidebarSectionDisclosureStore.maximumRememberedSections
        let entries = (0..<limit).map { ["projects", String($0)] }
        defaults.set(entries, forKey: SidebarSectionDisclosureStore.preferenceKey)
        let store = SidebarSectionDisclosureStore(defaults: defaults)
        // Repeated choices do not consume additional capacity.
        store.setCollapsed(true, providerID: "projects", sectionID: "1")
        store.setCollapsed(true, providerID: "other", sectionID: "new")

        let restored = SidebarSectionDisclosureStore(defaults: defaults)
        #expect(!restored.isCollapsed(providerID: "projects", sectionID: "0"))
        #expect(restored.isCollapsed(providerID: "projects", sectionID: "1"))
        #expect(restored.isCollapsed(providerID: "other", sectionID: "new"))
        #expect(defaults.array(forKey: SidebarSectionDisclosureStore.preferenceKey)?.count == limit)
    }

    @Test func normalizesOversizedAndMalformedPreferencesOnLoad() throws {
        let suite = "cmux.sidebar-disclosure-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let limit = SidebarSectionDisclosureStore.maximumRememberedSections
        let entries = (0...limit).map { ["projects", String($0)] }
        defaults.set(entries + [["projects", "1"], ["invalid"]], forKey: SidebarSectionDisclosureStore.preferenceKey)

        let store = SidebarSectionDisclosureStore(defaults: defaults)
        #expect(!store.isCollapsed(providerID: "projects", sectionID: "0"))
        #expect(store.isCollapsed(providerID: "projects", sectionID: "1"))
        #expect(store.isCollapsed(providerID: "projects", sectionID: String(limit)))
        #expect(defaults.array(forKey: SidebarSectionDisclosureStore.preferenceKey)?.count == limit)
    }

    @Test(.timeLimit(.minutes(1))) func windowsSharingStoreObserveEachOthersChoices() async throws {
        let suite = "cmux.sidebar-disclosure-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstWindow = SidebarSectionDisclosureStore(defaults: defaults)
        let secondWindow = firstWindow
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        withObservationTracking {
            _ = secondWindow.isCollapsed(providerID: "projects", sectionID: "shared")
        } onChange: {
            continuation.yield()
            continuation.finish()
        }
        firstWindow.setCollapsed(true, providerID: "projects", sectionID: "shared")
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(secondWindow.isCollapsed(providerID: "projects", sectionID: "shared"))
        secondWindow.setCollapsed(false, providerID: "projects", sectionID: "shared")
        #expect(!firstWindow.isCollapsed(providerID: "projects", sectionID: "shared"))
        #expect(!SidebarSectionDisclosureStore(defaults: defaults).isCollapsed(providerID: "projects", sectionID: "shared"))
    }
}
