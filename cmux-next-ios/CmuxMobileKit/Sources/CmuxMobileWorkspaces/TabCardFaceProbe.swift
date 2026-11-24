#if os(iOS)
import SwiftUI
import UIKit

/// Records which face a grid card draws (`AgentTabCard.Face`, or a browser
/// card's own snapshot, last-known picture or placeholder) for the UI tests'
/// probe (`TabCardFaceProbe`). Draws nothing and changes nothing; outside
/// DEBUG it is the content as it is.
struct TabCardFaceRecord: ViewModifier {
    let tabID: String?
    let face: String

    func body(content: Content) -> some View {
        #if DEBUG
        content.onChange(of: face, initial: true) { _, face in
            if let tabID { TabCardFaceProbe.record(face, tab: tabID) }
        }
        #else
        content
        #endif
    }
}

#if DEBUG
/// UI tests only (`-cmux-mobile-card-face-probe`): one accessibility element on
/// the window, `tabgrid.cardfaces.probe`, whose value says, per tab, the face its
/// grid card drew first in this launch (the grid is kept built while hidden,
/// so that may be before it showed) and the face it draws now, whether the
/// grid shows, and how many last-known pictures this launch wrote to disk:
/// `grid=1 saves=N saved=t-g2,t-g3 t-g3=live>lastKnown t-g2=placeholder>snapshot`. A card is one
/// accessibility element (TabsKit's card button), so its content cannot carry
/// an identifier a test reads; this probe does, as `TabBarProbe` does.
@MainActor
enum TabCardFaceProbe {
    static let isEnabled = CommandLine.arguments.contains("-cmux-mobile-card-face-probe")

    /// Per tab: the first face recorded this launch, and the latest.
    private static var faces: [String: (first: String, now: String)] = [:]
    private static weak var probe: ProbeView?
    private static var gridShown = false

    /// The grid showed (true) or was covered by a page (`WorkspaceTabsSource.overviewVisibilityChanged`).
    static func gridVisible(_ visible: Bool) {
        guard isEnabled else { return }
        gridShown = visible
        install()
    }

    static func record(_ face: String, tab: String) {
        guard isEnabled else { return }
        faces[tab] = (first: faces[tab]?.first ?? face, now: face)
        install()
    }

    static var summary: String {
        let cards = faces.keys.sorted().compactMap { tab in faces[tab].map { "\(tab)=\($0.first)>\($0.now)" } }
        return (["grid=\(gridShown ? 1 : 0)", "saves=\(TabCardSnapshots.shared.saves)",
                 "saved=" + (TabCardSnapshots.shared.savedTabs.isEmpty ? "-" : TabCardSnapshots.shared.savedTabs.sorted().joined(separator: ","))] + cards).joined(separator: " ")
    }

    /// Puts the probe on the key window once (above everything, no touches).
    private static func install() {
        guard probe?.window == nil else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let window else { return }
        let view = ProbeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        window.addSubview(view)
        probe = view
    }

    final class ProbeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = "tabgrid.cardfaces.probe"
            accessibilityLabel = "Card faces probe"
            accessibilityTraits = .staticText
        }

        required init?(coder: NSCoder) { nil }

        override var accessibilityValue: String? {
            get { TabCardFaceProbe.summary }
            set {}
        }
    }
}
#endif
#endif
