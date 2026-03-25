import AppKit
import SwiftUI

private let configurationErrorsWindowMinimumSize = NSSize(width: 480, height: 270)

protocol GhosttyConfigurationErrorsPresenting: AnyObject {
    var displayedErrors: [String] { get set }
    var isShowingConfigurationErrors: Bool { get }
    func showConfigurationErrorsWindow()
    func closeConfigurationErrorsWindow()
}

enum GhosttyConfigurationErrorsTrigger {
    case automatic
    case explicitReload
}

enum GhosttyConfigurationErrors {
    static func synchronize(
        _ errors: [String],
        presenter: GhosttyConfigurationErrorsPresenting,
        trigger: GhosttyConfigurationErrorsTrigger = .automatic
    ) {
        let previousErrors = presenter.displayedErrors
        let wasShowing = presenter.isShowingConfigurationErrors
        presenter.displayedErrors = errors

        if errors.isEmpty {
            presenter.closeConfigurationErrorsWindow()
            return
        }

        if !wasShowing,
           previousErrors == errors,
           trigger != .explicitReload {
            return
        }

        guard !wasShowing else { return }
        presenter.showConfigurationErrorsWindow()
    }
}

private protocol ConfigurationErrorsViewModel: ObservableObject {
    var displayedErrors: [String] { get }
    func dismissWarning()
    func reloadConfiguration()
}

final class ConfigurationErrorsController: NSWindowController, ObservableObject {
    static let shared = ConfigurationErrorsController()

    @Published var displayedErrors: [String] = []
    private var pendingPresentationWorkItem: DispatchWorkItem?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: configurationErrorsWindowMinimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        shouldCascadeWindows = false
        window.center()
        window.minSize = configurationErrorsWindowMinimumSize
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.configuration-errors")
        window.title = String(
            localized: "config.errors.title",
            defaultValue: "Configuration Errors"
        )
        window.contentView = NSHostingView(rootView: ConfigurationErrorsView(model: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension ConfigurationErrorsController: GhosttyConfigurationErrorsPresenting {
    var isShowingConfigurationErrors: Bool {
        window?.isVisible == true
    }

    func showConfigurationErrorsWindow() {
        pendingPresentationWorkItem?.cancel()
        pendingPresentationWorkItem = nil
        scheduleConfigurationErrorsWindowPresentation()
    }

    private func scheduleConfigurationErrorsWindowPresentation(retryDelay: TimeInterval? = nil) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.presentConfigurationErrorsWindowWhenReady()
        }
        pendingPresentationWorkItem = workItem
        if let retryDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    private func presentConfigurationErrorsWindowWhenReady() {
        guard let window else {
            pendingPresentationWorkItem = nil
            return
        }
        guard !displayedErrors.isEmpty else {
            pendingPresentationWorkItem = nil
            return
        }

        if AppDelegate.shared?.ensureMainWindowVisibleForConfigurationWarning() != nil {
            pendingPresentationWorkItem = nil
            window.orderFront(nil)
            return
        }

        scheduleConfigurationErrorsWindowPresentation(retryDelay: 0.05)
    }

    func closeConfigurationErrorsWindow() {
        pendingPresentationWorkItem?.cancel()
        pendingPresentationWorkItem = nil
        window?.performClose(nil)
    }
}

extension ConfigurationErrorsController: ConfigurationErrorsViewModel {
    func dismissWarning() {
        closeConfigurationErrorsWindow()
    }

    func reloadConfiguration() {
        GhosttyApp.shared.reloadConfiguration(source: "configuration_errors.reload_button")
    }
}

private struct ConfigurationErrorsView<Model: ConfigurationErrorsViewModel>: View {
    @ObservedObject var model: Model

    private var summaryText: String {
        let format = String(
            localized: "config.errors.summary",
            defaultValue: "%lld configuration error(s) were found. Review them below, reload your configuration, or close this warning and keep working."
        )
        return String(
            format: format,
            locale: Locale.current,
            Int64(model.displayedErrors.count)
        )
    }

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 52))
                    .padding()
                    .frame(alignment: .center)

                Text(summaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.displayedErrors, id: \.self) { error in
                            Text(error)
                                .lineLimit(nil)
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }

                        Spacer()
                    }
                    .padding(.all)
                    .frame(minHeight: geometry.size.height)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
            }

            HStack {
                Spacer()
                Button(
                    String(
                        localized: "config.errors.ignore",
                        defaultValue: "Close"
                    )
                ) {
                    model.dismissWarning()
                }
                Button(
                    String(
                        localized: "config.errors.reload",
                        defaultValue: "Reload Configuration"
                    )
                ) {
                    model.reloadConfiguration()
                }
            }
            .padding([.bottom, .trailing], 16)
        }
        .frame(minWidth: configurationErrorsWindowMinimumSize.width, maxWidth: 960, minHeight: configurationErrorsWindowMinimumSize.height)
    }
}
