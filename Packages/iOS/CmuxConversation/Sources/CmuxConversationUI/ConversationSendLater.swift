#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Send Later colors from ChatKit's asset catalog.
enum SendLaterStyle {
    static let clockBlue = UIColor(
        red: SendLaterClockGeometry.fill.red,
        green: SendLaterClockGeometry.fill.green,
        blue: SendLaterClockGeometry.fill.blue,
        alpha: 1
    )
    /// `EntryFieldSendLaterBalloonColor`: the composer field while Send Later is on.
    static let fieldFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(displayP3Red: 0.0549, green: 0.1216, blue: 0.2275, alpha: 1)
            : UIColor(displayP3Red: 0.9255, green: 0.9608, blue: 1, alpha: 1)
    }
    /// `EntryFieldSendLaterPressedBalloonColor`.
    static let fieldPressedFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(displayP3Red: 0.0745, green: 0.1647, blue: 0.3098, alpha: 1)
            : UIColor(displayP3Red: 0.8392, green: 0.9176, blue: 1, alpha: 1)
    }
    /// Outline of a scheduled bubble and of the composer time chip.
    static let outline = UIColor.systemBlue
    static let dashPattern: [NSNumber] = [5, 3.5]
    static let outlineWidth: CGFloat = 1.5

    static func timeText(_ date: Date) -> String { ConversationStore.sendLaterTimeText(date) }

    /// "**Send Later** Tomorrow at 9:00 AM Edit", "Edit" in the tint color.
    static func headerText(date: Date, failed: Bool) -> NSAttributedString {
        let gray: [NSAttributedString.Key: Any] = [.font: ConversationTheme.timestampFont, .foregroundColor: ConversationTheme.secondaryText]
        let result = NSMutableAttributedString(
            string: String(localized: "conversation.sendLater.transcript", defaultValue: "Send Later", bundle: .module),
            attributes: [.font: ConversationTheme.timestampBoldFont, .foregroundColor: failed ? ConversationTheme.notDelivered : ConversationTheme.secondaryText]
        )
        let time = timeText(date)
        let format = String(localized: "conversation.sendLater.timeEdit", defaultValue: "%@ Edit", bundle: .module)
        let line = String(format: format, time)
        let tail = NSMutableAttributedString(string: line, attributes: gray)
        let timeRange = (line as NSString).range(of: time)
        // Everything in the format besides the time is the "Edit" link.
        let whole = NSRange(location: 0, length: (line as NSString).length)
        if timeRange.location != NSNotFound {
            let before = NSRange(location: 0, length: timeRange.location)
            let after = NSRange(location: NSMaxRange(timeRange), length: whole.length - NSMaxRange(timeRange))
            for range in [before, after] where range.length > 0 {
                tail.addAttribute(.foregroundColor, value: UIColor.tintColor, range: range)
            }
        }
        result.append(NSAttributedString(string: " ", attributes: gray))
        result.append(tail)
        return result
    }

    /// The + menu icon (`send-menu-send-later-glass`): a dashed ring with the
    /// clock inside, both in the clock blue.
    static func menuIcon(side: CGFloat = 32, date: Date = Date()) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            let ring = side * 0.86
            let lineWidth = side * 0.075
            cg.setStrokeColor(clockBlue.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineCap(.round)
            cg.setLineDash(phase: 0, lengths: SendLaterClockGeometry.dashPattern(ringDiameter: ring))
            cg.strokeEllipse(in: CGRect(x: (side - ring) / 2, y: (side - ring) / 2, width: ring, height: ring))
            let clock = side * 0.42
            cg.setFillColor(clockBlue.cgColor)
            cg.addPath(SendLaterClockGeometry.path(diameter: clock, date: date, origin: CGPoint(x: (side - clock) / 2, y: (side - clock) / 2)))
            cg.fillPath()
        }
    }
}

/// The Send Later clock, layer for layer as in `clock-sendlater.ca`. Hands
/// are drawn in `cutoutColor` (the surface behind the clock) since UIKit has
/// no destination-out compositing; they sweep to each new time.
final class SendLaterClockView: UIView {
    private let face = CAShapeLayer()
    private let minuteHand = CAShapeLayer()
    private let hourHand = CAShapeLayer()
    private(set) var date: Date?
    var cutoutColor: UIColor = SendLaterStyle.fieldFill { didSet { updateColors() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(face)
        layer.addSublayer(hourHand)
        layer.addSublayer(minuteHand)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        face.frame = bounds
        face.path = UIBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)).cgPath
        for (hand, geometry) in [(minuteHand, SendLaterClockGeometry.minuteHand), (hourHand, SendLaterClockGeometry.hourHand)] {
            let rect = SendLaterClockGeometry.handRect(geometry, diameter: diameter)
            hand.bounds = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            hand.anchorPoint = CGPoint(x: 0.5, y: -rect.minY / rect.height)
            hand.position = center
            hand.path = UIBezierPath(roundedRect: hand.bounds, cornerRadius: rect.width / 2).cgPath
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        face.fillColor = SendLaterStyle.clockBlue.cgColor
        let cutout = cutoutColor.resolvedColor(with: traitCollection).cgColor
        minuteHand.fillColor = cutout
        hourHand.fillColor = cutout
    }

    /// Points the hands at `date`; animated, the minute hand sweeps forward
    /// through the minutes between the old and new time.
    func setDate(_ date: Date, animated: Bool) {
        let previous = self.date
        self.date = date
        let target: (hour: CGFloat, minute: CGFloat)
        if animated, let previous {
            target = SendLaterClockGeometry.sweep(from: previous, to: date)
        } else if animated {
            // First appearance sweeps in from 12:00.
            let midnight = Calendar.current.startOfDay(for: date)
            target = SendLaterClockGeometry.sweep(from: midnight.addingTimeInterval(12 * 3600), to: date)
            setAngles(hour: 0, minute: 0, animated: false)
        } else {
            target = SendLaterClockGeometry.angles(for: date)
        }
        setAngles(hour: target.hour, minute: target.minute, animated: animated)
    }

    private func setAngles(hour: CGFloat, minute: CGFloat, animated: Bool) {
        for (hand, angle) in [(hourHand, hour), (minuteHand, minute)] {
            let from = (hand.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? (hand.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
            hand.removeAnimation(forKey: "sweep")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hand.setValue(angle, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
            guard animated, abs(angle - from) > 0.001 else { continue }
            let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
            sweep.fromValue = from
            sweep.toValue = angle
            sweep.duration = 0.6
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hand.add(sweep, forKey: "sweep")
        }
    }
}

/// The time chip at the top of the composer field while Send Later is on:
/// clock, "Tomorrow at 9:00 AM" and a close button, in a dashed capsule.
final class SendLaterChipView: UIControl {
    let clock = SendLaterClockView()
    private let label = UILabel()
    let closeButton = UIButton(type: .system)
    private let outline = CAShapeLayer()
    var onEdit: (() -> Void)?
    var onClose: (() -> Void)?
    static let height: CGFloat = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(outline)
        outline.fillColor = nil
        outline.lineWidth = SendLaterStyle.outlineWidth
        outline.lineDashPattern = SendLaterStyle.dashPattern
        addSubview(clock)
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = .tintColor
        label.isUserInteractionEnabled = false
        addSubview(label)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = String(localized: "conversation.sendLater.close", defaultValue: "Close", bundle: .module)
        closeButton.accessibilityIdentifier = "conversation.sendLater.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        addSubview(closeButton)
        addAction(UIAction { [weak self] _ in self?.onEdit?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "conversation.sendLater.hint", defaultValue: "Double-tap to change date", bundle: .module)
        accessibilityIdentifier = "conversation.sendLater.chip"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: closeButton.accessibilityLabel ?? "") { [weak self] _ in
            self?.onClose?()
            return true
        }]
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date, animated: Bool) {
        label.text = SendLaterStyle.timeText(date)
        accessibilityLabel = label.text
        clock.setDate(date, animated: animated)
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? SendLaterStyle.fieldPressedFill : .clear }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: Self.height))
        return CGSize(width: min(size.width, 10 + 15 + 6 + ceil(text.width) + 4 + 26), height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        outline.frame = bounds
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: bounds.height / 2 - 0.75).cgPath
        clock.frame = CGRect(x: 10, y: (bounds.height - 15) / 2, width: 15, height: 15)
        closeButton.frame = CGRect(x: bounds.width - 28, y: 0, width: 26, height: bounds.height)
        label.frame = CGRect(x: clock.frame.maxX + 6, y: 0, width: max(0, closeButton.frame.minX - clock.frame.maxX - 6), height: bounds.height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        outline.strokeColor = SendLaterStyle.outline.resolvedColor(with: traitCollection).cgColor
    }
}

/// "Send Later Tomorrow at 9:00 AM Edit" above a scheduled bubble; Edit opens
/// Send Message, Edit Time and Delete Message.
final class SendLaterHeaderCell: UICollectionViewCell {
    static let reuseID = "sendLaterHeader"
    static let height: CGFloat = 32
    let button = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.showsMenuAsPrimaryAction = true
        button.titleLabel?.textAlignment = .center
        button.accessibilityIdentifier = "conversation.sendLater.edit"
        contentView.addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date, failed: Bool, menu: UIMenu) {
        button.setAttributedTitle(SendLaterStyle.headerText(date: date, failed: failed), for: .normal)
        button.menu = menu
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = contentView.bounds.inset(by: UIEdgeInsets(top: 10, left: 16, bottom: 4, right: 16))
    }
}

/// Edit Time: a date and time wheel limited to the next 14 days. Dismissing
/// the sheet (tapping away) keeps the new time.
final class SendLaterTimePickerController: UIViewController {
    let picker = UIDatePicker()
    private let onCommit: (Date) -> Void
    private var committed = false

    init(date: Date, now: Date = Date(), onCommit: @escaping (Date) -> Void) {
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
        picker.datePickerMode = .dateAndTime
        picker.preferredDatePickerStyle = .wheels
        picker.minimumDate = now
        picker.maximumDate = now.addingTimeInterval(ConversationStore.sendLaterHorizon)
        picker.date = min(max(date, now), now.addingTimeInterval(ConversationStore.sendLaterHorizon))
        picker.accessibilityIdentifier = "conversation.sendLater.picker"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            picker.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        ])
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom { _ in 260 }]
            sheet.prefersGrabberVisible = true
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard !committed else { return }
        committed = true
        onCommit(picker.date)
    }
}

extension ConversationViewController {
    /// The + menu entry.
    func sendLaterMenuItem() -> AppsMenuOverlay.Item {
        AppsMenuOverlay.Item(
            title: String(localized: "conversation.sendLater.menuItem", defaultValue: "Send Later", bundle: .module),
            symbol: "sendLater",
            color: .clear,
            customIcon: SendLaterStyle.menuIcon()
        ) { [weak self] in
            self?.enterSendLater()
        }
    }

    func enterSendLater() {
        if composer.sendLaterDate == nil {
            composer.setSendLaterDate(ConversationStore.defaultSendLaterDate(), animated: true)
        }
        composer.onSendLaterEdit = { [weak self] in self?.editComposerSendLaterTime() }
        composer.onSendLaterClose = { [weak self] in self?.composer.setSendLaterDate(nil, animated: true) }
        composer.textView.becomeFirstResponder()
    }

    private func editComposerSendLaterTime() {
        guard let date = composer.sendLaterDate else { return }
        presentSendLaterTimePicker(date: date) { [weak self] picked in
            self?.composer.setSendLaterDate(picked, animated: true)
        }
    }

    func presentSendLaterTimePicker(date: Date, onCommit: @escaping (Date) -> Void) {
        let picker = SendLaterTimePickerController(date: date, onCommit: onCommit)
        picker.modalPresentationStyle = .pageSheet
        present(picker, animated: true)
    }

    /// Sends the composer content as a scheduled message. Returns false when
    /// Send Later is off.
    func sendLaterIfNeeded(_ composer: ConversationComposerView) -> Bool {
        guard let date = composer.sendLaterDate else { return false }
        let images = composer.attachments.map { attachment in
            (data: attachment.data, width: Int(attachment.image.size.width * attachment.image.scale), height: Int(attachment.image.size.height * attachment.image.scale), mimeType: attachment.mimeType)
        }
        let text = composer.text
        let replyTo = replyTarget?.id
        // Send Later stays on (the chip remains) until it is closed.
        composer.clearAfterSend()
        photoDrawer?.clearSelection()
        pickedAssets = [:]
        store.scheduleSend(text: text, at: date, images: images, replyToID: replyTo)
        if replyTarget != nil { exitReplyMode() }
        return true
    }

    func sendLaterMenu(for rowID: String) -> UIMenu {
        let failed = store.message(rowID: rowID)?.delivery?.isFailed == true
        var actions: [UIMenuElement] = []
        if failed {
            actions.append(UIAction(title: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.store.retryScheduled(rowID: rowID)
            })
        }
        actions.append(UIAction(title: String(localized: "conversation.sendLater.sendNow", defaultValue: "Send Message", bundle: .module), image: UIImage(systemName: "arrow.up.circle")) { [weak self] _ in
            self?.store.sendScheduledNow(rowID: rowID)
        })
        actions.append(UIAction(title: String(localized: "conversation.sendLater.editTime", defaultValue: "Edit Time", bundle: .module), image: UIImage(systemName: "clock")) { [weak self] _ in
            guard let self, let date = self.store.message(rowID: rowID)?.scheduledAt else { return }
            self.presentSendLaterTimePicker(date: date) { [weak self] picked in
                self?.store.reschedule(rowID: rowID, to: picked)
            }
        })
        actions.append(UIAction(title: String(localized: "conversation.sendLater.delete", defaultValue: "Delete Message", bundle: .module), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.store.cancelScheduled(rowID: rowID)
        })
        return UIMenu(children: actions)
    }

    func presentScheduledActionFailure(_ failure: ConversationScheduledActionFailure) {
        let title: String
        let message: String?
        switch failure {
        case .notCancelled:
            title = String(localized: "conversation.sendLater.notCancelled.title", defaultValue: "Message Not Cancelled", bundle: .module)
            message = String(localized: "conversation.sendLater.notCancelled.message", defaultValue: "Your message was not cancelled. The original scheduled message might still be sent.", bundle: .module)
        case .notEdited:
            title = String(localized: "conversation.sendLater.notEdited.title", defaultValue: "Message Not Edited", bundle: .module)
            message = String(localized: "conversation.sendLater.notEdited.message", defaultValue: "Your message was not edited. The original scheduled message might still be sent.", bundle: .module)
        case .notSent:
            title = String(localized: "conversation.sendLater.notSent.title", defaultValue: "Message Not Sent", bundle: .module)
            message = String(localized: "conversation.sendLater.notSent.message", defaultValue: "Your message is still scheduled.", bundle: .module)
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "conversation.sendLater.ok", defaultValue: "OK", bundle: .module), style: .default))
        present(alert, animated: true)
    }
}
#endif
