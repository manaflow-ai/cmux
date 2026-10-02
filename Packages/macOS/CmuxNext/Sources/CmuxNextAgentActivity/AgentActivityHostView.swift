public import AppKit
import CmuxNextDesign
import SwiftUI

/// Hosts the Agent activity pane in a tab's content area. The App creates
/// it with a model over the real CUA host source; demos use
/// `AgentActivityMockSource`.
public final class AgentActivityHostView: NSView {
    public let model: AgentActivityModel
    private let hosting: NSHostingView<AgentActivityRoot>

    public init(model: AgentActivityModel) {
        self.model = model
        hosting = NSHostingView(rootView: AgentActivityRoot(model: model))
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Reads the layout tunable in a tracked scope so a Debug Settings change
/// switches the layout live.
struct AgentActivityRoot: View {
    let model: AgentActivityModel

    var body: some View {
        AgentActivityView(model: model, layout: AgentActivityTunables.layout.value)
    }
}
