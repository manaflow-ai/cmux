import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import CmuxUpdater
import CmuxUpdaterUI
import CmuxWorkspaces
import Observation

enum SidebarFooterButtonMetrics {
    static let buttonSize: CGFloat = 22
    static let profilePictureSize: CGFloat = 14
    static let profileIconSize: CGFloat = 14
    static let mobileIconSize: CGFloat = 12
    static let helpIconSize: CGFloat = 14
    static let hoverOpacity = 0.08
}

enum SidebarAccountButtonVisual: Equatable {
    case profilePicture
    case profileIcon(systemName: String)
}

struct SidebarAccountButtonPresentation: Equatable {
    static let defaultProfileIconSystemName = "person.crop.circle"

    let visual: SidebarAccountButtonVisual
    let size: CGFloat

    static func resolve(
        isSignedIn: Bool,
        prefersProfileIcon: Bool,
        hasProfilePicture: Bool = false
    ) -> SidebarAccountButtonPresentation {
        if isSignedIn, hasProfilePicture, !prefersProfileIcon {
            return SidebarAccountButtonPresentation(
                visual: .profilePicture,
                size: SidebarFooterButtonMetrics.profilePictureSize
            )
        }
        return SidebarAccountButtonPresentation(
            visual: .profileIcon(systemName: defaultProfileIconSystemName),
            size: SidebarFooterButtonMetrics.profileIconSize
        )
    }

    var showsProfilePicture: Bool { visual == .profilePicture }
}

enum SidebarFooterControl: CaseIterable, Equatable {
    case account
    case mobileConnect
    case help
    case shortcutDiscovery
    case upgrade
    case extensions
    case update
}

enum SidebarFooterPresentationPolicy {
    static func isVisible(
        _ control: SidebarFooterControl,
        presentationMode: WorkspacePresentationModeSettings.Mode
    ) -> Bool {
        presentationMode != .minimal || control == .upgrade
    }
}

#if DEBUG
enum SidebarFooterIconButtonDebugSettings {
    static let hoverOpacityKey = "debug.sidebarFooterIconButton.hoverOpacity"
    static let defaultHoverOpacity = SidebarFooterButtonMetrics.hoverOpacity
}

enum SidebarFooterProfileIconDebugChoice: String, CaseIterable, Identifiable {
    case outline = "person"
    case filled = "person.fill"
    case cropCircle = "person.crop.circle"
    case filledCropCircle = "person.crop.circle.fill"

    var id: String { rawValue }
}

enum SidebarFooterProfileIconDebugSettings {
    static let iconKey = "debug.sidebarFooterProfileIcon.symbol.v3"
    static let sizeKey = "debug.sidebarFooterProfileIcon.size"
    static let defaultIcon = SidebarFooterProfileIconDebugChoice.cropCircle
    static let defaultSize = Double(SidebarFooterButtonMetrics.profileIconSize)
}

enum SidebarFooterProfileDisplayDebugChoice: String, CaseIterable, Identifiable {
    case picture
    case icon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .picture:
            String(localized: "debug.sidebarFooterIconBalance.profileDisplay.picture", defaultValue: "Picture")
        case .icon:
            String(localized: "debug.sidebarFooterIconBalance.profileDisplay.icon", defaultValue: "Icon")
        }
    }
}

enum SidebarFooterProfileDisplayDebugSettings {
    static let displayKey = "debug.sidebarFooterProfile.display"
    static let defaultDisplay = SidebarFooterProfileDisplayDebugChoice.picture
}

enum SidebarFooterMobileIconDebugSettings {
    static let sizeKey = "debug.sidebarFooterMobileIcon.size"
    static let defaultSize = Double(SidebarFooterButtonMetrics.mobileIconSize)
}

enum SidebarFooterHelpIconDebugWeight: String, CaseIterable, Identifiable {
    case regular
    case medium
    case semibold

    var id: String { rawValue }

    var fontWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    var displayName: String {
        switch self {
        case .regular:
            String(localized: "debug.sidebarFooterIconBalance.weight.regular", defaultValue: "Regular")
        case .medium:
            String(localized: "debug.sidebarFooterIconBalance.weight.medium", defaultValue: "Medium")
        case .semibold:
            String(localized: "debug.sidebarFooterIconBalance.weight.semibold", defaultValue: "Semibold")
        }
    }
}

enum SidebarFooterHelpIconDebugChoice: String, CaseIterable, Identifiable {
    case bare = "questionmark"
    case circle = "questionmark.circle"
    case filledCircle = "questionmark.circle.fill"

    var id: String { rawValue }
}

enum SidebarFooterHelpIconDebugSettings {
    static let sizeKey = "debug.sidebarFooterHelpIcon.size"
    static let weightKey = "debug.sidebarFooterHelpIcon.weight"
    static let iconKey = "debug.sidebarFooterHelpIcon.symbol"
    static let defaultSize = Double(SidebarFooterButtonMetrics.helpIconSize)
    static let defaultWeight = SidebarFooterHelpIconDebugWeight.regular
    static let defaultIcon = SidebarFooterHelpIconDebugChoice.circle
}
#endif

@MainActor
private final class SidebarFooterActionButton: NSButton {
    var onPress: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var hovered = false

    override var isHighlighted: Bool {
        didSet { refreshBackground() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        target = self
        action = #selector(performAction(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(next)
        trackingAreaReference = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshBackground()
    }

    private func refreshBackground() {
        let opacity: CGFloat
        if !isEnabled {
            opacity = 0
        } else if isHighlighted {
            opacity = 0.16
        } else if hovered {
#if DEBUG
            opacity = CGFloat(UserDefaults.standard.object(
                forKey: SidebarFooterIconButtonDebugSettings.hoverOpacityKey
            ) as? Double ?? SidebarFooterIconButtonDebugSettings.defaultHoverOpacity)
#else
            opacity = SidebarFooterButtonMetrics.hoverOpacity
#endif
        } else {
            opacity = 0
        }
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(opacity).cgColor
    }

    @objc
    private func performAction(_ sender: NSButton) {
        onPress?()
    }
}

@MainActor
private final class SidebarFooterPopoverControl: NSView {
    let button = SidebarFooterActionButton(frame: .zero)
    private let anchor: ArrowlessPopoverAnchor
    private(set) var isPresented = false
    var onPresentationChange: ((Bool) -> Void)?

    init(contentViewController: NSViewController) {
        anchor = ArrowlessPopoverAnchor(
            isPresented: false,
            preferredEdge: .maxY,
            detachedGap: 4,
            contentViewController: contentViewController
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        anchor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(anchor)
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SidebarFooterButtonMetrics.buttonSize),
            heightAnchor.constraint(equalToConstant: SidebarFooterButtonMetrics.buttonSize),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            anchor.leadingAnchor.constraint(equalTo: leadingAnchor),
            anchor.trailingAnchor.constraint(equalTo: trailingAnchor),
            anchor.topAnchor.constraint(equalTo: topAnchor),
            anchor.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        button.onPress = { [weak self] in self?.toggle() }
        anchor.onPresentationChange = { [weak self] presented in
            guard let self else { return }
            isPresented = presented
            onPresentationChange?(presented)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateContentViewController(_ controller: NSViewController) {
        anchor.update(
            isPresented: isPresented,
            preferredEdge: .maxY,
            detachedGap: 4,
            contentViewController: controller
        )
    }

    func dismiss() {
        isPresented = false
        anchor.dismiss()
    }

    func present() {
        guard !isPresented else { return }
        isPresented = true
        anchor.present()
        onPresentationChange?(true)
    }

    func toggle() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }
}

@MainActor
private final class SidebarFooterAccountPopoverController: NSViewController {
    private weak var accountFlow: HostAccountFlow?
    private let dismiss: () -> Void

    init(accountFlow: HostAccountFlow?, dismiss: @escaping () -> Void) {
        self.accountFlow = accountFlow
        self.dismiss = dismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let identity = accountFlow?.currentIdentity {
            let identityRow = NSStackView()
            identityRow.orientation = .horizontal
            identityRow.alignment = .centerY
            identityRow.spacing = 10
            identityRow.addArrangedSubview(StackAccountAvatarView(
                avatarURL: identity.avatarURL,
                displayName: identity.displayName,
                email: identity.email,
                size: 34
            ))
            let labels = NSStackView()
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 2
            let primary = NSTextField(labelWithString: identity.displayName.isEmpty ? identity.email : identity.displayName)
            primary.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
            primary.lineBreakMode = .byTruncatingTail
            labels.addArrangedSubview(primary)
            if !identity.email.isEmpty, identity.email != identity.displayName {
                let secondary = NSTextField(labelWithString: identity.email)
                secondary.font = GlobalFontMagnification.systemFont(ofSize: 11)
                secondary.textColor = .secondaryLabelColor
                secondary.lineBreakMode = .byTruncatingTail
                labels.addArrangedSubview(secondary)
            }
            identityRow.addArrangedSubview(labels)
            stack.addArrangedSubview(identityRow)
            stack.addArrangedSubview(separator())
        } else {
            let signedOut = NSTextField(labelWithString: String(
                localized: "settings.account.signedOut.title",
                defaultValue: "Not signed in"
            ))
            signedOut.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
            stack.addArrangedSubview(signedOut)
            stack.addArrangedSubview(actionButton(
                title: String(localized: "settings.account.signIn", defaultValue: "Sign In…"),
                symbol: "person.crop.circle.badge.plus",
                accessibilityIdentifier: "SidebarAccountSignInButton"
            ) { [weak self] in
                self?.dismiss()
                self?.accountFlow?.startSignIn()
            })
        }

        if accountFlow?.isProUpgradeAvailable == true {
            if accountFlow?.currentIdentity == nil {
                stack.addArrangedSubview(separator())
            }
            stack.addArrangedSubview(actionButton(
                title: String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                symbol: "sparkles",
                accessibilityIdentifier: "SidebarAccountUpgradeButton"
            ) { [weak self] in
                self?.dismiss()
                self?.accountFlow?.openProUpgrade()
            })
        }

        if accountFlow?.currentIdentity != nil {
            stack.addArrangedSubview(actionButton(
                title: String(localized: "settings.account.signOut", defaultValue: "Sign Out"),
                symbol: "rectangle.portrait.and.arrow.right",
                accessibilityIdentifier: "SidebarAccountSignOutButton"
            ) { [weak self] in
                guard let self else { return }
                dismiss()
                Task { await self.accountFlow?.signOut() }
            })
        }

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 220),
        ])
        view = root
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func actionButton(
        title: String,
        symbol: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = SidebarFooterActionButton(frame: .zero)
        button.title = title
        button.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: symbol,
            pointSize: 12,
            weight: .regular
        )
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = GlobalFontMagnification.systemFont(ofSize: 12)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.onPress = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
}

@MainActor
private final class SidebarFooterHelpPopoverController: NSViewController {
    private enum Action {
        case upgrade
        case importBrowserData
        case keyboardShortcuts
        case docs
        case changelog
        case github
        case githubIssues
        case discord
        case checkForUpdates
        case sendFeedback
        case welcome
    }

    private let dismiss: () -> Void
    private let onSendFeedback: () -> Void

    init(dismiss: @escaping () -> Void, onSendFeedback: @escaping () -> Void) {
        self.dismiss = dismiss
        self.onSendFeedback = onSendFeedback
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addOption(
            to: stack,
            title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
            action: .welcome,
            accessibilityIdentifier: "SidebarHelpMenuOptionWelcome"
        )
        if CmuxFeatureFlags.shared.isProUpgradeUIEnabled {
            addOption(
                to: stack,
                title: String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                action: .upgrade,
                accessibilityIdentifier: "SidebarHelpMenuOptionUpgrade",
                trailingSymbol: "sparkles"
            )
        }
        addOption(
            to: stack,
            title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
            action: .sendFeedback,
            accessibilityIdentifier: "SidebarHelpMenuOptionSendFeedback",
            trailingText: KeyboardShortcutSettings.shortcut(for: .sendFeedback).displayString,
            trailingSymbol: "bubble.left.and.text.bubble.right"
        )
        addOption(
            to: stack,
            title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
            action: .keyboardShortcuts,
            accessibilityIdentifier: "SidebarHelpMenuOptionKeyboardShortcuts"
        )
        addOption(
            to: stack,
            title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
            action: .importBrowserData,
            accessibilityIdentifier: "SidebarHelpMenuOptionImportBrowserData"
        )
        addOption(to: stack, title: String(localized: "about.docs", defaultValue: "Docs"), action: .docs, accessibilityIdentifier: "SidebarHelpMenuOptionDocs", trailingSymbol: "arrow.up.right")
        addOption(to: stack, title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"), action: .changelog, accessibilityIdentifier: "SidebarHelpMenuOptionChangelog", trailingSymbol: "arrow.up.right")
        addOption(to: stack, title: String(localized: "about.github", defaultValue: "GitHub"), action: .github, accessibilityIdentifier: "SidebarHelpMenuOptionGitHub", trailingSymbol: "arrow.up.right")
        addOption(to: stack, title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"), action: .githubIssues, accessibilityIdentifier: "SidebarHelpMenuOptionGitHubIssues", trailingSymbol: "arrow.up.right")
        addOption(to: stack, title: String(localized: "sidebar.help.discord", defaultValue: "Discord"), action: .discord, accessibilityIdentifier: "SidebarHelpMenuOptionDiscord", trailingSymbol: "arrow.up.right")
        addOption(
            to: stack,
            title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
            action: .checkForUpdates,
            accessibilityIdentifier: "SidebarHelpMenuOptionCheckForUpdates"
        )

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        view = root
    }

    private func addOption(
        to stack: NSStackView,
        title: String,
        action: Action,
        accessibilityIdentifier: String,
        trailingText: String? = nil,
        trailingSymbol: String? = nil
    ) {
        let button = SidebarFooterActionButton(frame: .zero)
        button.title = title
        button.alignment = .left
        button.font = GlobalFontMagnification.systemFont(ofSize: 12)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        var suffix = [trailingText].compactMap { $0 }
        if trailingSymbol == "arrow.up.right" {
            suffix.append("↗")
        }
        if !suffix.isEmpty {
            button.title += "    " + suffix.joined(separator: "  ")
        }
        button.onPress = { [weak self] in self?.perform(action) }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(button)
    }

    private func perform(_ action: Action) {
        dismiss()
        switch action {
        case .upgrade:
            ProUpgradePresenter.present()
        case .importBrowserData:
            Task { @MainActor in
                await Task.yield()
                BrowserDataImportCoordinator.shared.presentImportDialog()
            }
        case .keyboardShortcuts:
            Task { @MainActor in
                await Task.yield()
                if let appDelegate = AppDelegate.shared {
                    appDelegate.openPreferencesWindow(
                        debugSource: "sidebarHelpMenu.keyboardShortcuts",
                        navigationTarget: .keyboardShortcuts
                    )
                } else {
                    AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                }
            }
        case .docs:
            NSWorkspace.shared.open(URL(string: "https://cmux.com/docs")!)
        case .changelog:
            NSWorkspace.shared.open(URL(string: "https://cmux.com/docs/changelog")!)
        case .github:
            NSWorkspace.shared.open(URL(string: "https://github.com/manaflow-ai/cmux")!)
        case .githubIssues:
            NSWorkspace.shared.open(URL(string: "https://github.com/manaflow-ai/cmux/issues")!)
        case .discord:
            NSWorkspace.shared.open(URL(string: "https://discord.gg/xsgFEVrWCZ")!)
        case .checkForUpdates:
            AppDelegate.shared?.checkForUpdates(nil)
        case .sendFeedback:
            onSendFeedback()
        case .welcome:
            AppDelegate.shared?.openWelcomeWorkspace()
        }
    }
}

/// AppKit owner for the sidebar footer. It observes the same models as the
/// previous declarative footer while keeping popovers and controls mounted.
@MainActor
final class SidebarFooterNativeViewController: NSViewController {
    private let updateViewModel: UpdateStateModel
    private weak var tabManager: TabManager?
    private let modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor
    private let onSendFeedback: () -> Void

    private let controlsStack = NSStackView()
    private let accountPopoverController: SidebarFooterAccountPopoverController
    private let helpPopoverController: SidebarFooterHelpPopoverController
    private let accountControl: SidebarFooterPopoverControl
    private let helpControl: SidebarFooterPopoverControl
    private let mobileButton = SidebarFooterActionButton(frame: .zero)
    private let shortcutButton = ShortcutDiscoveryButtonView(frame: .zero)
    private let proBadge = ProBadgeView(frame: .zero)
    private let extensionsButton = SidebarFooterActionButton(frame: .zero)
    private var updatePill: UpdatePillView?
    private var avatarView: StackAccountAvatarView?
    private var defaultsObserver: NSObjectProtocol?
    private var featureFlagsObserver: NSObjectProtocol?
    private var observationGeneration: UInt64 = 0
    private var shortcutPopoverPresented = false

#if DEBUG
    private let debugBanner = NSTextField(labelWithString: String(
        localized: "debug.devBuildBanner.title",
        defaultValue: "THIS IS A DEV BUILD"
    ))
#endif

    init(
        updateViewModel: UpdateStateModel,
        tabManager: TabManager,
        modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor,
        onSendFeedback: @escaping () -> Void
    ) {
        self.updateViewModel = updateViewModel
        self.tabManager = tabManager
        self.modifierKeyMonitor = modifierKeyMonitor
        self.onSendFeedback = onSendFeedback

        var accountDismiss: (() -> Void)!
        accountPopoverController = SidebarFooterAccountPopoverController(
            accountFlow: AppDelegate.shared?.auth?.accountFlow,
            dismiss: { accountDismiss?() }
        )
        accountControl = SidebarFooterPopoverControl(contentViewController: accountPopoverController)
        accountDismiss = { [weak accountControl] in accountControl?.dismiss() }

        var helpDismiss: (() -> Void)!
        helpPopoverController = SidebarFooterHelpPopoverController(
            dismiss: { helpDismiss?() },
            onSendFeedback: onSendFeedback
        )
        helpControl = SidebarFooterPopoverControl(contentViewController: helpPopoverController)
        helpDismiss = { [weak helpControl] in helpControl?.dismiss() }

        super.init(nibName: nil, bundle: nil)
        configureControls()
        observeInputs()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        observationGeneration &+= 1
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let featureFlagsObserver { NotificationCenter.default.removeObserver(featureFlagsObserver) }
        shortcutButton.teardown()
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = 4
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

#if DEBUG
        debugBanner.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .semibold)
        debugBanner.textColor = .systemRed
        let rootStack = NSStackView(views: [controlsStack, debugBanner])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 6
#else
        let rootStack = NSStackView(views: [controlsStack])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
#endif
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            rootStack.topAnchor.constraint(equalTo: root.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        render()
    }

    func update(
        tabManager: TabManager,
        modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor,
        onSendFeedback: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        render()
    }

    func teardown() {
        observationGeneration &+= 1
        accountControl.dismiss()
        helpControl.dismiss()
        shortcutButton.teardown()
    }

    private func configureControls() {
        configureSymbolButton(
            mobileButton,
            systemName: "iphone",
            pointSize: resolvedMobileIconSize,
            weight: .medium,
            title: String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad"),
            accessibilityIdentifier: "SidebarMobileConnectButton"
        )
        mobileButton.onPress = { [weak self] in
            guard let self, let tabManager else { return }
            _ = AppDelegate.shared?.performMobileConnectWorkspaceAction(
                tabManager: tabManager,
                debugSource: "sidebar.mobileConnect"
            )
        }

        configureSymbolButton(
            helpControl.button,
            systemName: resolvedHelpIconName,
            pointSize: resolvedHelpIconSize,
            weight: resolvedHelpIconWeight,
            title: String(localized: "sidebar.help.button", defaultValue: "Help"),
            accessibilityIdentifier: "SidebarHelpMenuButton"
        )

        configureSymbolButton(
            extensionsButton,
            systemName: "puzzlepiece.extension",
            pointSize: 12,
            weight: .medium,
            title: String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"),
            accessibilityIdentifier: "SidebarExtensionMenuButton"
        )
        extensionsButton.onPress = { [weak self] in
            guard let self else { return }
            _ = AppDelegate.shared?.openSidebarExtensionBrowser(
                from: extensionsButton,
                title: String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
            )
        }

        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutButton.widthAnchor.constraint(equalToConstant: SidebarFooterButtonMetrics.buttonSize).isActive = true
        shortcutButton.heightAnchor.constraint(equalToConstant: SidebarFooterButtonMetrics.buttonSize).isActive = true
        shortcutButton.update(isPresented: false) { [weak self] presented in
            self?.shortcutPopoverPresented = presented
            self?.render()
        }
    }

    private func configureSymbolButton(
        _ button: SidebarFooterActionButton,
        systemName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        title: String,
        accessibilityIdentifier: String
    ) {
        button.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: systemName,
            pointSize: pointSize,
            weight: weight
        )
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: SidebarFooterButtonMetrics.buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: SidebarFooterButtonMetrics.buttonSize).isActive = true
    }

    private func updateSymbolButtonImage(
        _ button: NSButton,
        systemName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight
    ) {
        button.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: systemName,
            pointSize: pointSize,
            weight: weight
        )
    }

    private func observeInputs() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        featureFlagsObserver = NotificationCenter.default.addObserver(
            forName: .cmuxFeatureFlagsDidChange,
            object: CmuxFeatureFlags.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        observeTrackedInputs()
    }

    private func observeTrackedInputs() {
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            _ = modifierKeyMonitor.isModifierPressed
            _ = AppDelegate.shared?.auth?.accountFlow.currentIdentity
            _ = AppDelegate.shared?.auth?.accountFlow.isWorkingOnAuth
            _ = AppDelegate.shared?.auth?.accountFlow.isProUpgradeAvailable
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, observationGeneration == generation else { return }
                render()
                observeTrackedInputs()
            }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        let mode = WorkspacePresentationModeSettings.mode(
            for: UserDefaults.standard.string(forKey: WorkspacePresentationModeSettings.modeKey)
                ?? WorkspacePresentationModeSettings.defaultMode.rawValue
        )
        let shows: (SidebarFooterControl) -> Bool = {
            SidebarFooterPresentationPolicy.isVisible($0, presentationMode: mode)
        }

        updateAccountControl()
        updateSymbolButtonImage(
            mobileButton,
            systemName: "iphone",
            pointSize: resolvedMobileIconSize,
            weight: .medium
        )
        updateSymbolButtonImage(
            helpControl.button,
            systemName: resolvedHelpIconName,
            pointSize: resolvedHelpIconSize,
            weight: resolvedHelpIconWeight
        )

        controlsStack.arrangedSubviews.forEach {
            controlsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if shows(.account), CmuxFeatureFlags.shared.isSidebarAccountButtonEnabled {
            controlsStack.addArrangedSubview(accountControl)
        }
        if shows(.mobileConnect), CmuxFeatureFlags.shared.isMobileConnectButtonEnabled {
            controlsStack.addArrangedSubview(mobileButton)
        }
        if shows(.help) {
            controlsStack.addArrangedSubview(helpControl)
        }
        let showModifierHints = UserDefaults.standard.object(
            forKey: SettingCatalog().shortcuts.showModifierHoldHints.userDefaultsKey
        ) as? Bool ?? SettingCatalog().shortcuts.showModifierHoldHints.defaultValue
        if shows(.shortcutDiscovery),
           (showModifierHints && modifierKeyMonitor.isModifierPressed) || shortcutPopoverPresented {
            controlsStack.addArrangedSubview(shortcutButton)
        }
        if shows(.upgrade) {
            controlsStack.addArrangedSubview(proBadge)
        }
        let extensionsKey = SettingCatalog().betaFeatures.extensions
        let extensionsEnabled = UserDefaults.standard.object(forKey: extensionsKey.userDefaultsKey) as? Bool
            ?? extensionsKey.defaultValue
        if shows(.extensions), extensionsEnabled {
            controlsStack.addArrangedSubview(extensionsButton)
        }
        if shows(.update), let actions = AppDelegate.shared {
            let pill = updatePill ?? UpdatePillView(
                model: updateViewModel,
                accent: cmuxAccentNSColor(),
                actions: actions
            )
            updatePill = pill
            pill.setAccentColor(cmuxAccentNSColor())
            controlsStack.addArrangedSubview(pill)
        }

#if DEBUG
        let storedBannerVisibility = UserDefaults.standard.object(
            forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey
        ) as? Bool
        debugBanner.isHidden = !(storedBannerVisibility
            ?? DevBuildBannerDebugSettings.defaultShowSidebarBanner)
#endif
        view.invalidateIntrinsicContentSize()
    }

    private func updateAccountControl() {
        let flow = AppDelegate.shared?.auth?.accountFlow
        let identity = flow?.currentIdentity
        let prefersProfileIcon: Bool
#if DEBUG
        prefersProfileIcon = SidebarFooterProfileDisplayDebugChoice(
            rawValue: UserDefaults.standard.string(
                forKey: SidebarFooterProfileDisplayDebugSettings.displayKey
            ) ?? SidebarFooterProfileDisplayDebugSettings.defaultDisplay.rawValue
        ) == .icon
#else
        prefersProfileIcon = false
#endif
        let presentation = SidebarAccountButtonPresentation.resolve(
            isSignedIn: identity != nil,
            prefersProfileIcon: prefersProfileIcon,
            hasProfilePicture: identity?.avatarURL != nil
        )
        let size: CGFloat
#if DEBUG
        size = presentation.showsProfilePicture
            ? presentation.size
            : CGFloat(UserDefaults.standard.object(
                forKey: SidebarFooterProfileIconDebugSettings.sizeKey
            ) as? Double ?? SidebarFooterProfileIconDebugSettings.defaultSize)
#else
        size = presentation.size
#endif

        avatarView?.removeFromSuperview()
        let avatar = StackAccountAvatarView(
            avatarURL: presentation.showsProfilePicture ? identity?.avatarURL : nil,
            displayName: presentation.showsProfilePicture ? (identity?.displayName ?? "") : "",
            email: presentation.showsProfilePicture ? (identity?.email ?? "") : "",
            size: size,
            loadingSystemName: resolvedProfileIconName
        )
        avatar.translatesAutoresizingMaskIntoConstraints = false
        accountControl.addSubview(avatar, positioned: .below, relativeTo: accountControl.button)
        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: accountControl.centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: accountControl.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: size),
            avatar.heightAnchor.constraint(equalToConstant: size),
        ])
        avatarView = avatar

        let title = identity == nil
            ? String(localized: "settings.account.signIn", defaultValue: "Sign In…")
            : String(localized: "settings.section.account", defaultValue: "Account")
        accountControl.button.toolTip = title
        accountControl.button.setAccessibilityLabel(title)
        accountControl.button.setAccessibilityIdentifier("SidebarAccountMenuButton")
        accountControl.button.isEnabled = flow?.isWorkingOnAuth != true
        accountControl.button.onPress = { [weak self] in
            guard let self else { return }
            if flow?.currentIdentity == nil {
                guard let tabManager else { return }
                _ = AppDelegate.shared?.performAccountSignInWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "sidebar.account"
                )
            } else {
                accountControl.updateContentViewController(SidebarFooterAccountPopoverController(
                    accountFlow: flow,
                    dismiss: { [weak accountControl] in accountControl?.dismiss() }
                ))
                accountControl.toggle()
            }
        }
    }

    private var resolvedProfileIconName: String {
#if DEBUG
        return UserDefaults.standard.string(forKey: SidebarFooterProfileIconDebugSettings.iconKey)
            ?? SidebarFooterProfileIconDebugSettings.defaultIcon.rawValue
#else
        return SidebarAccountButtonPresentation.defaultProfileIconSystemName
#endif
    }

    private var resolvedMobileIconSize: CGFloat {
#if DEBUG
        return CGFloat(UserDefaults.standard.object(
            forKey: SidebarFooterMobileIconDebugSettings.sizeKey
        ) as? Double ?? SidebarFooterMobileIconDebugSettings.defaultSize)
#else
        return SidebarFooterButtonMetrics.mobileIconSize
#endif
    }

    private var resolvedHelpIconName: String {
#if DEBUG
        return UserDefaults.standard.string(forKey: SidebarFooterHelpIconDebugSettings.iconKey)
            ?? SidebarFooterHelpIconDebugSettings.defaultIcon.rawValue
#else
        return "questionmark.circle"
#endif
    }

    private var resolvedHelpIconSize: CGFloat {
#if DEBUG
        return CGFloat(UserDefaults.standard.object(
            forKey: SidebarFooterHelpIconDebugSettings.sizeKey
        ) as? Double ?? SidebarFooterHelpIconDebugSettings.defaultSize)
#else
        return SidebarFooterButtonMetrics.helpIconSize
#endif
    }

    private var resolvedHelpIconWeight: NSFont.Weight {
#if DEBUG
        switch SidebarFooterHelpIconDebugWeight(rawValue: UserDefaults.standard.string(
            forKey: SidebarFooterHelpIconDebugSettings.weightKey
        ) ?? SidebarFooterHelpIconDebugSettings.defaultWeight.rawValue) {
        case .medium: return .medium
        case .semibold: return .semibold
        case .regular, nil: return .regular
        }
#else
        return .regular
#endif
    }
}
