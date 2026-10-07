#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry

/// Send Later colors from ChatKit's asset catalog (macOS Messages runs the
/// same ChatKit through Catalyst).
enum MacSendLaterStyle {
    static let clockBlue = NSColor(
        srgbRed: SendLaterClockGeometry.fill.red,
        green: SendLaterClockGeometry.fill.green,
        blue: SendLaterClockGeometry.fill.blue,
        alpha: 1
    )
    /// `EntryFieldSendLaterBalloonColor`.
    static let fieldFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(displayP3Red: 0.0549, green: 0.1216, blue: 0.2275, alpha: 1)
            : NSColor(displayP3Red: 0.9255, green: 0.9608, blue: 1, alpha: 1)
    }
    static let outline = NSColor.systemBlue
    static let dashPattern: [NSNumber] = [4.5, 3]
    static let outlineWidth: CGFloat = 1.25

    static func headerText(date: Date, failed: Bool) -> NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let gray: [NSAttributedString.Key: Any] = [.font: MacConversationTheme.timestampFont, .foregroundColor: MacConversationTheme.secondaryText, .paragraphStyle: centered]
        let result = NSMutableAttributedString(
            string: String(localized: "conversation.sendLater.transcript", defaultValue: "Send Later", bundle: .module),
            attributes: [.font: MacConversationTheme.timestampBoldFont, .foregroundColor: failed ? NSColor.systemRed : MacConversationTheme.secondaryText, .paragraphStyle: centered]
        )
        let time = ConversationStore.sendLaterTimeText(date)
        let line = String(format: String(localized: "conversation.sendLater.timeEdit", defaultValue: "%@ Edit", bundle: .module), time)
        let tail = NSMutableAttributedString(string: line, attributes: gray)
        let timeRange = (line as NSString).range(of: time)
        if timeRange.location != NSNotFound {
            let length = (line as NSString).length
            for range in [NSRange(location: 0, length: timeRange.location), NSRange(location: NSMaxRange(timeRange), length: length - NSMaxRange(timeRange))] where range.length > 0 {
                tail.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            }
        }
        result.append(NSAttributedString(string: " ", attributes: gray))
        result.append(tail)
        return result
    }

    /// The send menu icon (`Mac-SendLaterIcon-glass`): dashed ring, clock inside.
    static func menuIcon(side: CGFloat = 16, date: Date = Date()) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let ring = side * 0.86
            cg.setStrokeColor(clockBlue.cgColor)
            cg.setLineWidth(side * 0.08)
            cg.setLineCap(.round)
            cg.setLineDash(phase: 0, lengths: SendLaterClockGeometry.dashPattern(ringDiameter: ring))
            cg.strokeEllipse(in: CGRect(x: (side - ring) / 2, y: (side - ring) / 2, width: ring, height: ring))
            let clock = side * 0.46
            cg.setLineDash(phase: 0, lengths: [])
            cg.setFillColor(clockBlue.cgColor)
            cg.addPath(SendLaterClockGeometry.path(diameter: clock, date: date, origin: CGPoint(x: (side - clock) / 2, y: (side - clock) / 2)))
            cg.fillPath()
            return true
        }
        return image
    }
}

/// `clock-sendlater.ca`: a blue face with the hands cut out (drawn in the
/// surface color behind it), turned to the scheduled time.
final class MacSendLaterClockView: MacFlippedView {
    private let face = CAShapeLayer()
    private let minuteHand = CAShapeLayer()
    private let hourHand = CAShapeLayer()
    private(set) var date: Date?
    var cutoutColor: NSColor = MacSendLaterStyle.fieldFill { didSet { updateColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(face)
        layer?.addSublayer(hourHand)
        layer?.addSublayer(minuteHand)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let diameter = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        face.frame = bounds
        face.path = CGPath(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter), transform: nil)
        for (hand, geometry) in [(minuteHand, SendLaterClockGeometry.minuteHand), (hourHand, SendLaterClockGeometry.hourHand)] {
            let rect = SendLaterClockGeometry.handRect(geometry, diameter: diameter)
            hand.bounds = CGRect(origin: .zero, size: rect.size)
            hand.anchorPoint = CGPoint(x: 0.5, y: -rect.minY / rect.height)
            hand.position = center
            hand.path = CGPath(roundedRect: hand.bounds, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: nil)
        }
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        face.fillColor = MacSendLaterStyle.clockBlue.cgColor
        let cutout = resolved(cutoutColor, in: self)
        minuteHand.fillColor = cutout
        hourHand.fillColor = cutout
    }

    func setDate(_ date: Date, animated: Bool) {
        let previous = self.date
        self.date = date
        // The layer is flipped (y down), so a positive z rotation runs clockwise.
        let target = previous.map { SendLaterClockGeometry.sweep(from: $0, to: date) } ?? SendLaterClockGeometry.angles(for: date)
        for (hand, angle) in [(hourHand, target.hour), (minuteHand, target.minute)] {
            let from = (hand.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hand.setValue(angle, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
            guard animated, previous != nil, abs(angle - from) > 0.001 else { continue }
            let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
            sweep.fromValue = from
            sweep.toValue = angle
            sweep.duration = 0.6
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hand.add(sweep, forKey: "sweep")
        }
    }
}

/// The composer's time chip while Send Later is on: clock, time, close.
final class MacSendLaterChipView: MacFlippedView {
    let clock = MacSendLaterClockView()
    private let label = makeMacLabel()
    let closeButton = NSButton()
    private let outline = CAShapeLayer()
    var onEdit: (() -> Void)?
    var onClose: (() -> Void)?
    static let height: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(outline)
        outline.fillColor = nil
        outline.lineWidth = MacSendLaterStyle.outlineWidth
        outline.lineDashPattern = MacSendLaterStyle.dashPattern
        addSubview(clock)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .controlAccentColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "conversation.sendLater.close", defaultValue: "Close", bundle: .module))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setAccessibilityIdentifier("conversation.sendLater.close")
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("conversation.sendLater.chip")
        let menu = NSMenu()
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.sendLater.editTime", defaultValue: "Edit Time", bundle: .module)) { [weak self] in self?.onEdit?() })
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.sendLater.cancel", defaultValue: "Cancel Send Later", bundle: .module)) { [weak self] in self?.onClose?() })
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date, animated: Bool) {
        label.stringValue = ConversationStore.sendLaterTimeText(date)
        setAccessibilityLabel(label.stringValue)
        clock.setDate(date, animated: animated)
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        let text = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? .systemFont(ofSize: 12)])
        return 7 + 12 + 5 + ceil(text.width) + 6 + 18
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6), cornerWidth: bounds.height / 2 - 0.6, cornerHeight: bounds.height / 2 - 0.6, transform: nil)
        outline.strokeColor = resolved(MacSendLaterStyle.outline, in: self)
        clock.frame = CGRect(x: 7, y: (bounds.height - 12) / 2, width: 12, height: 12)
        closeButton.frame = CGRect(x: bounds.width - 20, y: 0, width: 18, height: bounds.height)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: clock.frame.maxX + 5, y: (bounds.height - labelHeight) / 2, width: max(0, closeButton.frame.minX - clock.frame.maxX - 5), height: labelHeight)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(local) { return super.mouseDown(with: event) }
        onEdit?()
    }

    override func accessibilityPerformPress() -> Bool {
        onEdit?()
        return true
    }

    @objc private func closeTapped() { onClose?() }
}

/// "Send Later Tomorrow at 9:00 AM Edit" above a scheduled bubble; a click
/// opens Send Message, Edit Time and Delete Message.
final class MacSendLaterHeaderRowView: MacFlippedView {
    let label = makeMacLabel()
    static let height: CGFloat = 26
    var menuProvider: (() -> NSMenu)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("conversation.sendLater.edit")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date, failed: Bool) {
        label.attributedStringValue = MacSendLaterStyle.headerText(date: date, failed: failed)
        setAccessibilityLabel(label.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: 8, width: bounds.width, height: 14)
    }

    override func mouseDown(with event: NSEvent) {
        showMenu(at: convert(event.locationInWindow, from: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        showMenu(at: NSPoint(x: bounds.midX, y: label.frame.maxY))
        return true
    }

    func showMenu(at point: NSPoint) {
        menuProvider?().popUp(positioning: nil, at: point, in: self)
    }
}

/// Edit Time: a calendar and clock limited to the next 14 days; closing the
/// popover keeps the new time.
final class MacSendLaterTimePickerController: NSViewController, NSPopoverDelegate {
    let picker = NSDatePicker()
    private let onCommit: (Date) -> Void
    private var committed = false

    init(date: Date, now: Date = Date(), onCommit: @escaping (Date) -> Void) {
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.minDate = now
        picker.maxDate = now.addingTimeInterval(ConversationStore.sendLaterHorizon)
        picker.dateValue = min(max(date, now), now.addingTimeInterval(ConversationStore.sendLaterHorizon))
        picker.setAccessibilityIdentifier("conversation.sendLater.picker")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            picker.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            picker.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
    }

    func commit() {
        guard !committed else { return }
        committed = true
        onCommit(picker.dateValue)
    }

    func popoverWillClose(_ notification: Notification) { commit() }
}

extension MacConversationViewController {
    func sendLaterAppsMenuItem() -> NSMenuItem {
        let item = MacClosureMenuItem(title: String(localized: "conversation.sendLater.menuItemEllipsis", defaultValue: "Send Later…", bundle: .module)) { [weak self] in
            self?.enterSendLater()
        }
        item.image = MacSendLaterStyle.menuIcon()
        return item
    }

    func enterSendLater() {
        if composer.sendLaterDate == nil {
            composer.setSendLaterDate(ConversationStore.defaultSendLaterDate(), animated: true)
        }
        composer.onSendLaterEdit = { [weak self] in
            guard let self, let date = self.composer.sendLaterDate else { return }
            self.presentSendLaterTimePicker(date: date, from: self.composer.sendLaterChip) { [weak self] picked in
                self?.composer.setSendLaterDate(picked, animated: true)
            }
        }
        composer.onSendLaterClose = { [weak self] in self?.composer.setSendLaterDate(nil, animated: true) }
        view.window?.makeFirstResponder(composer.textView)
    }

    @discardableResult
    func presentSendLaterTimePicker(date: Date, from anchor: NSView, onCommit: @escaping (Date) -> Void) -> MacSendLaterTimePickerController {
        let controller = MacSendLaterTimePickerController(date: date, onCommit: onCommit)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        sendLaterPopover = popover
        return controller
    }

    /// Schedules the composer content when Send Later is on.
    func scheduleIfSendLater(_ composer: MacComposerView) -> Bool {
        guard let date = composer.sendLaterDate else { return false }
        let images = composer.attachments.map { attachment in
            (data: attachment.data, width: Int(attachment.image.size.width), height: Int(attachment.image.size.height), mimeType: attachment.mimeType)
        }
        let text = composer.text
        let replyTo = replyTarget?.id
        composer.clearAfterSend()
        store.scheduleSend(text: text, at: date, images: images, replyToID: replyTo)
        return true
    }

    /// Edit link menu: Send Message, Edit Time, Delete Message (Try Again
    /// first when it will not send).
    func sendLaterMenu(rowID: String, anchor: NSView, cancelTitle: Bool = false) -> NSMenu {
        let menu = NSMenu()
        if store.message(rowID: rowID)?.delivery?.isFailed == true {
            menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.sendLater.tryAgain", defaultValue: "Try Again", bundle: .module)) { [weak self] in
                self?.store.retryScheduled(rowID: rowID)
            })
        }
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.sendLater.sendNow", defaultValue: "Send Message", bundle: .module)) { [weak self] in
            self?.store.sendScheduledNow(rowID: rowID)
        })
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.sendLater.editTime", defaultValue: "Edit Time", bundle: .module)) { [weak self, weak anchor] in
            guard let self, let anchor, let date = self.store.message(rowID: rowID)?.scheduledAt else { return }
            self.presentSendLaterTimePicker(date: date, from: anchor) { [weak self] picked in
                self?.store.reschedule(rowID: rowID, to: picked)
            }
        })
        let removeTitle = cancelTitle
            ? String(localized: "conversation.sendLater.cancel", defaultValue: "Cancel Send Later", bundle: .module)
            : String(localized: "conversation.sendLater.delete", defaultValue: "Delete Message", bundle: .module)
        menu.addItem(MacClosureMenuItem(title: removeTitle) { [weak self] in
            self?.store.cancelScheduled(rowID: rowID)
        })
        return menu
    }

    func presentScheduledActionFailure(_ failure: ConversationScheduledActionFailure) {
        let alert = NSAlert()
        switch failure {
        case .notCancelled:
            alert.messageText = String(localized: "conversation.sendLater.notCancelled.title", defaultValue: "Message Not Cancelled", bundle: .module)
            alert.informativeText = String(localized: "conversation.sendLater.notCancelled.message", defaultValue: "Your message was not cancelled. The original scheduled message might still be sent.", bundle: .module)
        case .notEdited:
            alert.messageText = String(localized: "conversation.sendLater.notEdited.title", defaultValue: "Message Not Edited", bundle: .module)
            alert.informativeText = String(localized: "conversation.sendLater.notEdited.message", defaultValue: "Your message was not edited. The original scheduled message might still be sent.", bundle: .module)
        case .notSent:
            alert.messageText = String(localized: "conversation.sendLater.notSent.title", defaultValue: "Message Not Sent", bundle: .module)
            alert.informativeText = String(localized: "conversation.sendLater.notSent.message", defaultValue: "Your message is still scheduled.", bundle: .module)
        }
        alert.addButton(withTitle: String(localized: "conversation.sendLater.ok", defaultValue: "OK", bundle: .module))
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    #if DEBUG
    /// Lab verbs: sl.enter, sl.time <minutes>, sl.close, sl.schedule <seconds> <text>,
    /// sl.sendnow, sl.cancel, sl.retime <minutes>, sl.retry, sl.menu, sl.picker, sl.state.
    func sendLaterLabCommand(_ verb: String, _ argument: String) -> String {
        let last = store.scheduledMessages.last?.rowID
        switch verb {
        case "sl.enter":
            enterSendLater()
            return "ok \(composer.sendLaterDate.map { ConversationStore.sendLaterTimeText($0) } ?? "-")"
        case "sl.time":
            composer.setSendLaterDate(Date().addingTimeInterval((Double(argument) ?? 60) * 60), animated: true)
            return "ok"
        case "sl.close":
            composer.onSendLaterClose?()
            return "ok"
        case "sl.picker":
            composer.onSendLaterEdit?()
            return sendLaterPopover?.isShown == true ? "ok" : "error no popover"
        case "sl.pickerclose":
            sendLaterPopover?.close()
            return "ok"
        case "sl.schedule":
            let p = argument.split(separator: " ", maxSplits: 1).map(String.init)
            store.scheduleSend(text: p.count > 1 ? p[1] : "later", at: Date().addingTimeInterval(Double(p.first ?? "") ?? 60))
            return "ok"
        case "sl.sendnow":
            guard let last else { return "error none" }
            store.sendScheduledNow(rowID: last)
            return "ok"
        case "sl.cancel":
            guard let last else { return "error none" }
            store.cancelScheduled(rowID: last)
            return "ok"
        case "sl.retime":
            guard let last else { return "error none" }
            store.reschedule(rowID: last, to: Date().addingTimeInterval((Double(argument) ?? 120) * 60))
            return "ok"
        case "sl.retry":
            guard let failed = store.scheduledMessages.first(where: { $0.delivery?.isFailed == true }) else { return "error none" }
            store.retryScheduled(rowID: failed.rowID)
            return "ok"
        case "sl.menu":
            guard let index = rows.lastIndex(where: { if case .sendLaterHeader = $0 { return true } else { return false } }) else { return "error none" }
            tableView.scrollRowToVisible(index)
            guard let header = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacSendLaterHeaderRowView,
                  let menu = header.menuProvider?() else { return "error not visible" }
            return "menu " + menu.items.map(\.title).joined(separator: "|")
        case "sl.render":
            // Renders the window's layer tree to a PNG (no Screen Recording needed).
            // sl.render <path> [field]: the window, or just the composer field
            // content (glass does not render through layer.render).
            let args = argument.split(separator: " ").map(String.init)
            let path = args.first ?? "/tmp/sl.png"
            let target: NSView? = args.count > 1 ? composer.sendLaterChip.superview : view.window?.contentView
            guard let content = target, let layer = content.layer else { return "error no window" }
            let scale: CGFloat = 2
            let size = content.bounds.size
            guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "error context" }
            context.setFillColor(resolved(.windowBackgroundColor, in: content))
            context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            context.scaleBy(x: scale, y: scale)
            if content.isFlipped {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            NSAppearance.current = content.effectiveAppearance
            layer.render(in: context)
            guard let image = context.makeImage(),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "error image" }
            do { try data.write(to: URL(fileURLWithPath: path)) } catch { return "error \(error)" }
            return "ok \(path)"
        case "sl.state":
            let list = store.scheduledMessages.map { "\($0.id):\($0.delivery.map { "\($0)" } ?? "-"):\(Int($0.scheduledAt!.timeIntervalSinceNow))" }
            return "scheduled \(list.joined(separator: ",")) chip \(composer.sendLaterDate.map { ConversationStore.sendLaterTimeText($0) } ?? "-")"
        default:
            return "error unknown \(verb)"
        }
    }
    #endif
}
#endif
