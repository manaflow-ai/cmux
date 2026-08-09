import UIKit

@MainActor
final class TerminalRuntimeErrorViewController: UIViewController {
    private let error: Error

    init(error: Error) {
        self.error = error
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .headline)
        title.text = String(
            localized: "runtime.error.title",
            defaultValue: "Ghostty could not start"
        )

        let detail = UILabel()
        detail.font = .preferredFont(forTextStyle: .body)
        detail.numberOfLines = 0
        detail.text = error.localizedDescription

        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
