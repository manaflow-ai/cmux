#if canImport(UIKit) && DEBUG
public import UIKit

/// DEBUG-only UIKit exercise screen for every toast style and queue behavior.
/// Dev-facing strings are intentionally unlocalized.
@MainActor
public final class ToastGalleryViewController: UITableViewController {
    private enum Action: CaseIterable {
        case success
        case failure
        case warning
        case info
        case infoIcon
        case withAction
        case longMessage
        case persistent
        case bottom
        case queueThree
        case coalesce
        case uniqueSpam
        case dismissAll

        var title: String {
            switch self {
            case .success: "Success"
            case .failure: "Failure with title"
            case .warning: "Warning"
            case .info: "Info"
            case .infoIcon: "Info with icon"
            case .withAction: "With action"
            case .longMessage: "Long message"
            case .persistent: "Persistent"
            case .bottom: "Bottom placement"
            case .queueThree: "Queue three"
            case .coalesce: "Coalesce (tap repeatedly)"
            case .uniqueSpam: "Unique spam"
            case .dismissAll: "Dismiss all"
            }
        }

        var identifier: String? {
            switch self {
            case .success: "ToastGallerySuccess"
            case .failure: "ToastGalleryFailure"
            case .info: "ToastGalleryInfo"
            case .withAction: "ToastGalleryAction"
            case .bottom: "ToastGalleryBottom"
            case .queueThree: "ToastGalleryQueue"
            case .coalesce: "ToastGalleryCoalesce"
            default: nil
            }
        }
    }

    private static let sections: [(title: String, actions: [Action])] = [
        ("Styles", [.success, .failure, .warning, .info, .infoIcon]),
        ("Composition", [.withAction, .longMessage, .persistent, .bottom]),
        ("Behavior", [.queueThree, .coalesce, .uniqueSpam, .dismissAll]),
    ]

    private let toasts: ToastCenter
    private var uniqueCounter = 0
    private var autorunTask: Task<Void, Never>?

    public init(center: ToastCenter) {
        toasts = center
        super.init(style: .insetGrouped)
        title = "Toasts"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.environment["CMUX_TOAST_GALLERY_AUTORUN"] == "1" else { return }
        autorunTask?.cancel()
        autorunTask = Task { [weak self] in await self?.runAutodemo() }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        autorunTask?.cancel()
        autorunTask = nil
    }

    public override func numberOfSections(in tableView: UITableView) -> Int {
        Self.sections.count
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Self.sections[section].title
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Self.sections[section].actions.count
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "toast-action")
            ?? UITableViewCell(style: .default, reuseIdentifier: "toast-action")
        let action = Self.sections[indexPath.section].actions[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = action.title
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.accessibilityIdentifier = action.identifier
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        perform(Self.sections[indexPath.section].actions[indexPath.row])
    }

    private func perform(_ action: Action) {
        switch action {
        case .success:
            toasts.present(.success("Workspace created"))
        case .failure:
            toasts.present(.failure("Not connected to your Mac.", title: "Couldn't rename workspace"))
        case .warning:
            toasts.present(.warning("This Mac is running an older cmux build."))
        case .info:
            toasts.present(.info("Agent finished in workspace api-fix"))
        case .infoIcon:
            toasts.present(.info("Copied to clipboard", systemImage: "doc.on.doc"))
        case .withAction:
            toasts.present(.failure("The request timed out.", title: "Couldn't create workspace", action: Toast.Action(label: "Retry") {}))
        case .longMessage:
            toasts.present(.failure("The connection to your Mac was interrupted while the workspace list was refreshing, so the latest changes may not be shown until it reconnects.", title: "Sync interrupted"))
        case .persistent:
            toasts.present(.warning("Reconnecting to your Mac…", autoDismiss: .never, coalescingKey: "gallery.persistent"))
        case .bottom:
            toasts.present(.success("Saved", placement: .bottom))
        case .queueThree:
            toasts.present(.success("First: workspace created"))
            toasts.present(.info("Second: agent finished"))
            toasts.present(.warning("Third: build is out of date"))
        case .coalesce:
            toasts.present(.failure("Not connected to your Mac.", title: "Couldn't pin workspace"))
        case .uniqueSpam:
            uniqueCounter += 1
            toasts.present(.info("Notice #\(uniqueCounter)"))
        case .dismissAll:
            toasts.dismissAll()
        }
    }

    private func runAutodemo() async {
        let clock = ContinuousClock()
        do {
            try await clock.sleep(for: .seconds(2))
            try await recordPassthroughProbe(clock: clock)
        } catch {
            return
        }
        ToastDemo.run(on: toasts)
    }

    private func recordPassthroughProbe(clock: ContinuousClock) async throws {
        var lines: [String] = []
        defer {
            let url = URL.documentsDirectory.appending(path: "toast-probe.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard let overlay = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0 is ToastPassthroughWindow }) else {
            lines.append("FAIL overlay window not found")
            return
        }
        let center = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        let empty = overlay.hitTest(center, with: nil)
        lines.append(empty == nil
            ? "PASS empty overlay passes touches through (hitTest nil)"
            : "FAIL empty overlay captured touch: \(type(of: empty!))")

        toasts.present(.info("Passthrough probe", coalescingKey: "probe"))
        try await clock.sleep(for: .milliseconds(800))
        lines.append("presented=\(String(describing: toasts.presented?.toast.message)) safeTop=\(overlay.safeAreaInsets.top)")
        var hitAny = false
        for y in stride(from: 4, through: 120, by: 8) {
            let point = CGPoint(x: overlay.bounds.midX, y: overlay.safeAreaInsets.top + CGFloat(y))
            if let hit = overlay.hitTest(point, with: nil) {
                hitAny = true
                lines.append("hit y=+\(y): \(type(of: hit))")
            }
        }
        lines.append(hitAny ? "PASS toast region captures touch" : "FAIL toast region did not hit-test at any scanned point")
        let besideToast = overlay.hitTest(center, with: nil)
        lines.append(besideToast == nil
            ? "PASS area beside visible toast still passes through"
            : "FAIL area beside toast captured: \(type(of: besideToast!))")
        toasts.dismissAll()
        try await clock.sleep(for: .milliseconds(800))
    }
}
#endif
