import AppKit

/// Realized text target for the legacy SwiftUI list. It changes its string,
/// tooltip, and intrinsic width only when the displayed elapsed bucket changes.
@MainActor
final class SidebarAgentActivityTextField: NSTextField, SidebarAgentElapsedClockTarget {
    private var activity = SidebarWorkspaceAgentActivity(agents: [])
    private var clock: SidebarAgentElapsedClockActions?
    private var isClockRegistered = false
    private var displayedState: SidebarAgentResolvedState?
    private var elapsedDisplayBucket: Int64?

    init() {
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byClipping
        cell?.usesSingleLineMode = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(
        activity: SidebarWorkspaceAgentActivity,
        color: NSColor,
        fontSize: CGFloat,
        clock: SidebarAgentElapsedClockActions
    ) {
        let contentChanged = self.activity != activity
        let colorChanged = textColor != color
        let intendedFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let fontChanged = font != intendedFont
        let styleChanged = colorChanged || fontChanged
        self.activity = activity
        if colorChanged {
            textColor = color
        }
        if fontChanged {
            font = intendedFont
        }
        if styleChanged {
            invalidateIntrinsicContentSize()
        }
        setClock(clock)
        refreshClockRegistration()
        updateDisplay(at: .now, force: contentChanged || styleChanged)
    }

    func disconnectClock() {
        if isClockRegistered {
            clock?.unregister(self)
        }
        isClockRegistered = false
        clock = nil
    }

    func sidebarAgentElapsedClockDidTick(at now: Date) {
        guard isClockRegistered else { return }
        updateDisplay(at: now, force: false)
    }

    private func setClock(_ nextClock: SidebarAgentElapsedClockActions) {
        guard clock?.identity != nextClock.identity else { return }
        if isClockRegistered {
            clock?.unregister(self)
            isClockRegistered = false
        }
        clock = nextClock
    }

    private func refreshClockRegistration() {
        let shouldRegister = activity.primaryState == .running
            && activity.primaryElapsedStart != nil
        if shouldRegister, !isClockRegistered {
            clock?.register(self)
            isClockRegistered = true
        } else if !shouldRegister, isClockRegistered {
            clock?.unregister(self)
            isClockRegistered = false
        }
    }

    private func updateDisplay(at now: Date, force: Bool) {
        guard let state = activity.primaryState else {
            if force || displayedState != nil {
                displayedState = nil
                elapsedDisplayBucket = nil
                apply(text: "", toolTip: nil, accessibilityLabel: nil)
            }
            return
        }

        let elapsed = state == .running ? activity.elapsed(at: now) : nil
        let bucket = elapsed.map(SidebarWorkspaceAgentActivity.compactElapsedDisplayBucket)
        guard force || displayedState != state || elapsedDisplayBucket != bucket else { return }
        displayedState = state
        elapsedDisplayBucket = bucket

        if elapsed != nil {
            let payload = clock?.displayPayload(activity, now)
                ?? SidebarAgentActivityDisplayPayload(activity: activity, at: now)
            apply(
                text: payload.text,
                toolTip: payload.toolTip,
                accessibilityLabel: payload.accessibilityLabel
            )
        } else {
            let payload = clock?.displayPayload(activity, now)
                ?? SidebarAgentActivityDisplayPayload(activity: activity, at: now)
            apply(
                text: payload.text,
                toolTip: payload.toolTip,
                accessibilityLabel: payload.accessibilityLabel
            )
        }
    }

    private func apply(text: String, toolTip: String?, accessibilityLabel: String?) {
        let widthChanged = stringValue != text
        if widthChanged {
            stringValue = text
            invalidateIntrinsicContentSize()
        }
        if self.toolTip != toolTip {
            self.toolTip = toolTip
        }
        setAccessibilityLabel(accessibilityLabel)
    }
}
