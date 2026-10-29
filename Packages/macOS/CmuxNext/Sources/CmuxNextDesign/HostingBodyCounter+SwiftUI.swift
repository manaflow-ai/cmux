public import AppKit
public import SwiftUI

// The SwiftUI side of the gate's body counter (VisibilityGatedHostingView.swift, HostingBodyCounter.swift):
// a root that counts its own body evaluations (the page's mounts and the environment passes that reach the
// root), attributed to the node's state, for debug.observations and the benches. A page whose own views
// read its model records those bodies itself into the same counter, as Tasks does (TasksRoot, TasksView).
// It goes when the last gated page is AppKit.

extension VisibilityGatedHostingView {
    /// Hosts `content`, built in the root's body; each evaluation of the root counts (``bodyEvaluations``,
    /// `debug.observations`). Model changes that only the content's own views read do not run the root.
    public convenience init<Content: View>(owner: String, policy: Policy = .gated,
                                           @ViewBuilder content: @escaping @MainActor () -> Content) {
        let counter = HostingBodyCounter()
        self.init(owner: owner, policy: policy, counter: counter,
                  hosting: NSHostingView(rootView: HostingBodyCountedRoot(counter: counter, content: content)))
    }
}

/// The root of a gated hosting view: builds the page's content in its body and counts each evaluation.
struct HostingBodyCountedRoot<Content: View>: View {
    let counter: HostingBodyCounter
    let content: @MainActor () -> Content

    var body: some View {
        counter.record()
        return content()
    }
}
