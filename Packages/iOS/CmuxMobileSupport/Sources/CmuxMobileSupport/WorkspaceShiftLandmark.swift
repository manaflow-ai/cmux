#if DEBUG && os(iOS)
public import SwiftUI
public import UIKit

/// The workspace transition test samples these views on the display clock. The weak
/// registrations follow reuse and never keep a workspace, cell or text field alive.
@MainActor
public struct WorkspaceShiftLandmark: View {
    public static let enabled = CommandLine.arguments.contains("-cmux-mobile-workspace-shift-trace")
    private static let workspaceID = ProcessInfo.processInfo.environment["CMUX_SHIFT_WORKSPACE_ID"]
    private static let views = NSMapTable<UIView, NSString>.weakToStrongObjects()
    private let id: String

    public init(_ id: String) { self.id = id }

    public var body: some View {
        if Self.enabled { Marker(id: id).allowsHitTesting(false).accessibilityHidden(true) }
    }

    public static func register(_ view: UIView, id: String) {
        guard enabled else { return }
        views.setObject(id as NSString, forKey: view)
    }

    public static func registerRow(_ view: UIView, workspaceID id: String) {
        guard enabled else { return }
        if id == workspaceID { register(view, id: "workspace.row.\(id)") }
        else { views.removeObject(forKey: view) }
    }

    public static func registered(in window: UIWindow) -> [(id: String, view: UIView)] {
        views.keyEnumerator().compactMap { object in
            guard let view = object as? UIView, view.window === window,
                  let id = views.object(forKey: view) else { return nil }
            return (id as String, view)
        }
    }

    private struct Marker: UIViewRepresentable {
        let id: String

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {
            WorkspaceShiftLandmark.register(view, id: id)
        }
    }
}
#endif
