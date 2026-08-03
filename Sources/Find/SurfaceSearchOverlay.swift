import AppKit
import CmuxFoundation
import CmuxTerminal
import Combine

@MainActor
final class SurfaceSearchOverlay: NativeSearchOverlayView {
    private weak var surfaceView: GhosttyNSView?

    init(
        tabId: UUID,
        surfaceId: UUID,
        searchState: TerminalSurface.SearchState,
        canApplyFocusRequest: @escaping () -> Bool,
        onNavigateSearch: @escaping (TerminalSearchNavigation) -> Void,
        onSearchTextChanged: @escaping () -> Void,
        onFieldDidFocus: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        super.init(configuration: Self.configuration(
            surfaceId: surfaceId,
            searchState: searchState,
            canApplyFocusRequest: canApplyFocusRequest,
            onNavigateSearch: onNavigateSearch,
            onSearchTextChanged: onSearchTextChanged,
            onFieldDidFocus: onFieldDidFocus,
            onClose: onClose
        ))
        setAccessibilityIdentifier("TerminalFindSearchOverlay")
#if DEBUG
        cmuxDebugLog(
            "find.overlay.appear tab=\(tabId.uuidString.prefix(5)) surface=\(surfaceId.uuidString.prefix(5))"
        )
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attachSurfaceView(_ surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
    }

    override func mouseDragged(with event: NSEvent) {
        guard surfaceView?.forwardPendingLeftMouseDrag(with: event) != true else { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard surfaceView?.completePendingLeftMouseRelease(with: event) != true else { return }
        super.mouseUp(with: event)
    }

    func update(
        surfaceId: UUID,
        searchState: TerminalSurface.SearchState,
        canApplyFocusRequest: @escaping () -> Bool,
        onNavigateSearch: @escaping (TerminalSearchNavigation) -> Void,
        onSearchTextChanged: @escaping () -> Void,
        onFieldDidFocus: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        update(configuration: Self.configuration(
            surfaceId: surfaceId,
            searchState: searchState,
            canApplyFocusRequest: canApplyFocusRequest,
            onNavigateSearch: onNavigateSearch,
            onSearchTextChanged: onSearchTextChanged,
            onFieldDidFocus: onFieldDidFocus,
            onClose: onClose
        ))
    }

    private static func configuration(
        surfaceId: UUID,
        searchState: TerminalSurface.SearchState,
        canApplyFocusRequest: @escaping () -> Bool,
        onNavigateSearch: @escaping (TerminalSearchNavigation) -> Void,
        onSearchTextChanged: @escaping () -> Void,
        onFieldDidFocus: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> NativeSearchOverlayConfiguration {
        NativeSearchOverlayConfiguration(
            identity: surfaceId,
            debugScope: "terminal",
            fieldAccessibilityIdentifier: "TerminalFindSearchTextField",
            selectionOwner: searchState,
            stateChanges: Publishers.CombineLatest3(searchState.$needle, searchState.$selected, searchState.$total)
                .map { _ in () }
                .eraseToAnyPublisher(),
            needle: { searchState.needle },
            setNeedle: { searchState.needle = $0 },
            selected: { searchState.selected },
            total: { searchState.total },
            focusNotificationName: .ghosttySearchFocus,
            matchesFocusNotification: { notification in
                (notification.object as? TerminalSurface)?.id == surfaceId
            },
            canApplyFocusRequest: canApplyFocusRequest,
            onNext: { onNavigateSearch(.next) },
            onPrevious: { onNavigateSearch(.previous) },
            onClose: onClose,
            onTextChanged: onSearchTextChanged,
            onFieldDidFocus: onFieldDidFocus
        )
    }
}
