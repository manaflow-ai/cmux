#if os(iOS)
public import CmuxAgentGUIProjection
import CmuxAgentReplica
public import UIKit

/// Production container that embeds the transcript list in a host view controller.
@MainActor public final class TranscriptLiveContainerViewController: UIViewController {
    let transcript: TranscriptListViewController
    private(set) var terminalThemeGeneration: UInt64
    private var currentTheme: AgentGUITheme
    private var requestedBottomChromeViews: [UIView] = []
    private var hostedBottomChrome: [(view: UIView, originalSuperview: UIView, originalIndex: Int)] = []
    private var scrollsToTopRestorations: [ObjectIdentifier: TranscriptScrollsToTopRestoration] = [:]
    private var ownsScrollsToTop = false

    /// Creates a live container with the current terminal-derived palette.
    public init(theme: AgentGUITheme, terminalThemeGeneration: UInt64) {
        transcript = TranscriptListViewController(theme: theme)
        self.terminalThemeGeneration = terminalThemeGeneration
        currentTheme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        MainActor.assumeIsolated {
            prepareForDismantle()
        }
    }

    /// Installs a root that passes uncovered transcript chrome touches to the host below.
    public override func loadView() {
        view = TranscriptChromePassthroughView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(currentTheme.background)
        addChild(transcript)
        transcript.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript.view)
        transcript.didMove(toParent: self)

        NSLayoutConstraint.activate([
            transcript.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reconcileBottomChromeHosting()
        if ownsScrollsToTop {
            reconcileScrollsToTopOwnership()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ownsScrollsToTop = true
        reconcileScrollsToTopOwnership()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        restoreScrollsToTopOwnership()
        super.viewDidDisappear(animated)
    }

    public override func willMove(toParent parent: UIViewController?) {
        if parent == nil {
            prepareForDismantle()
        }
        super.willMove(toParent: parent)
    }

    /// Applies the latest transcript projection input to the embedded list.
    /// - Parameter input: Projection input built from a live conversation replica.
    public func apply(input: TranscriptProjectionInput) {
        loadViewIfNeeded()
        transcript.apply(input: input)
        if ownsScrollsToTop {
            reconcileScrollsToTopOwnership()
        }
    }

    func applyPendingAskInteraction(
        answeringAskID: String?,
        failedAskID: String?,
        onAnswer: @escaping (PendingAsk, Int) -> Void,
        onShowTerminal: @escaping () -> Void
    ) {
        transcript.applyPendingAskInteraction(
            answeringAskID: answeringAskID,
            failedAskID: failedAskID,
            onAnswer: onAnswer,
            onShowTerminal: onShowTerminal
        )
    }

    func applyActivityPresentation(
        onShowActivity: @escaping (TranscriptActivityDetails) -> Void
    ) {
        transcript.applyActivityPresentation(onShowActivity: onShowActivity)
    }

    /// Recolors the mounted transcript without replacing its list or collection view.
    public func apply(theme: AgentGUITheme, terminalThemeGeneration: UInt64) {
        self.terminalThemeGeneration = terminalThemeGeneration
        currentTheme = theme
        if isViewLoaded {
            view.backgroundColor = UIColor(theme.background)
        }
        transcript.apply(theme: theme)
    }

    /// Scrolls the transcript to the newest row.
    public func scrollToBottom() {
        transcript.scrollToBottom()
    }

    /// Updates the transcript's bottom inset for composer chrome.
    /// - Parameter height: Height occupied by chrome over the transcript bottom.
    public func setBottomChromeHeight(_ height: CGFloat) {
        transcript.setBottomChromeHeight(height)
    }

    /// Registers the live composer and accessory views that shape the native bottom fade.
    /// - Parameter containers: Real floating chrome containers owned by the terminal surface.
    public func setBottomEdgeElementContainers(_ containers: [UIView]) {
        let uniqueContainers = containers.reduce(into: [UIView]()) { result, container in
            guard !result.contains(where: { $0 === container }) else { return }
            result.append(container)
        }
        guard uniqueContainers.map(ObjectIdentifier.init)
            != requestedBottomChromeViews.map(ObjectIdentifier.init)
        else {
            return
        }
        restoreBottomChromeHosting()
        requestedBottomChromeViews = uniqueContainers
        transcript.setBottomEdgeElementContainers(containers)
        reconcileBottomChromeHosting()
        if ownsScrollsToTop {
            reconcileScrollsToTopOwnership()
        }
    }

    /// Restores terminal-owned chrome and removes transcript edge interactions.
    public func prepareForDismantle() {
        restoreScrollsToTopOwnership()
        restoreBottomChromeHosting()
        requestedBottomChromeViews.removeAll()
        transcript.prepareForDismantle()
    }

    /// Applies the transcript spacing and metadata-type register.
    /// - Parameter density: The density selected in mobile display settings.
    public func setDensity(_ density: TranscriptDensity) {
        transcript.setDensity(density)
    }

    private func reconcileBottomChromeHosting() {
        guard view.window != nil, hostedBottomChrome.isEmpty else { return }
        for chromeView in requestedBottomChromeViews {
            guard let originalSuperview = chromeView.superview else { continue }
            let originalIndex = originalSuperview.subviews.firstIndex(where: { $0 === chromeView }) ?? 0
            let frameInHost = originalSuperview.convert(chromeView.frame, to: view)
            hostedBottomChrome.append((chromeView, originalSuperview, originalIndex))
            view.addSubview(chromeView)
            chromeView.frame = frameInHost
        }
    }

    private func restoreBottomChromeHosting() {
        for hosted in hostedBottomChrome.reversed() {
            let frameInOriginalSuperview = view.convert(hosted.view.frame, to: hosted.originalSuperview)
            let insertionIndex = min(hosted.originalIndex, hosted.originalSuperview.subviews.count)
            hosted.originalSuperview.insertSubview(hosted.view, at: insertionIndex)
            hosted.view.frame = frameInOriginalSuperview
        }
        hostedBottomChrome.removeAll()
    }

    private func reconcileScrollsToTopOwnership() {
        guard let hierarchyRoot = view.window else { return }
        scrollsToTopRestorations = scrollsToTopRestorations.filter { $0.value.scrollView != nil }
        let transcriptScrollView = transcript.collectionView
        for scrollView in allScrollViews(in: hierarchyRoot) {
            let identifier = ObjectIdentifier(scrollView)
            if scrollsToTopRestorations[identifier] == nil {
                scrollsToTopRestorations[identifier] = TranscriptScrollsToTopRestoration(
                    scrollView: scrollView,
                    originalValue: scrollView.scrollsToTop
                )
            }
            scrollView.scrollsToTop = scrollView === transcriptScrollView
        }
    }

    private func restoreScrollsToTopOwnership() {
        for restoration in scrollsToTopRestorations.values {
            restoration.scrollView?.scrollsToTop = restoration.originalValue
        }
        scrollsToTopRestorations.removeAll()
        ownsScrollsToTop = false
    }

    private func allScrollViews(in root: UIView) -> [UIScrollView] {
        let current = (root as? UIScrollView).map { [$0] } ?? []
        return current + root.subviews.flatMap { allScrollViews(in: $0) }
    }
}
#endif
