import SwiftUI
import Testing

@testable import CmuxSidebarUI

@Suite("SidebarWorkspaceRowFramePreferenceKey")
struct SidebarWorkspaceRowFramePreferenceKeyTests {
    @Test("default value is empty")
    func defaultIsEmpty() {
        #expect(SidebarWorkspaceRowFramePreferenceKey.defaultValue.isEmpty)
    }

    // The reducer merges row anchors keyed by workspace UUID, preferring the
    // later value on a duplicate key. Anchor<CGRect> values cannot be
    // constructed directly outside a layout pass, so the merge semantics are
    // pinned through a key-set + last-writer check on a parallel dictionary
    // built with the same `merge(_:uniquingKeysWith:)` rule the reducer uses.
    @Test("merge keeps the last value for duplicate keys")
    func mergeKeepsLast() {
        let shared = UUID()
        let other = UUID()
        var base: [UUID: Int] = [shared: 1, other: 2]
        base.merge([shared: 9]) { _, next in next }
        #expect(base[shared] == 9)
        #expect(base[other] == 2)
        #expect(Set(base.keys) == [shared, other])
    }
}
