#if os(iOS)
import SwiftUI
import UIKit

typealias SelectionMenuRows = @MainActor (UIView) -> [UIMenuElement]

extension EnvironmentValues {
    @Entry var selectionMenuRows: SelectionMenuRows? = nil
}

public extension View {
    /// A selected table cell or code block can offer both its own actions and the enclosing message's.
    func selectionMenu(_ rows: @escaping @MainActor (UIView) -> [UIMenuElement]) -> some View {
        transformEnvironment(\.selectionMenuRows) { inherited in
            let outer = inherited
            inherited = { source in rows(source) + (outer?(source) ?? []) }
        }
    }
}

@MainActor
public enum SelectionMenu {
    public static func action(_ title: String, _ symbol: String, perform: @escaping @MainActor () -> Void) -> UIAction {
        UIAction(title: NSLocalizedString(title, comment: ""), image: UIImage(systemName: symbol)) { _ in perform() }
    }

    public static func share(_ text: @autoclosure @escaping @MainActor () -> String, from source: UIView, title: String = "Share") -> UIAction {
        action(title, "square.and.arrow.up") { [weak source] in
            guard let source, var presenter = source.window?.rootViewController else { return }
            while let presented = presenter.presentedViewController { presenter = presented }
            let sheet = UIActivityViewController(activityItems: [text()], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = source
            sheet.popoverPresentationController?.sourceRect = source.bounds
            presenter.present(sheet, animated: true)
        }
    }
}
#endif
