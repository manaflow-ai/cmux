import AppKit
import Darwin
import Foundation

enum SerialConsoleParity: String, Codable, CaseIterable, Sendable {
    case none
    case even
    case odd

    var localizedTitle: String {
        switch self {
        case .none:
            return String(localized: "serial.open.parity.none", defaultValue: "None")
        case .even:
            return String(localized: "serial.open.parity.even", defaultValue: "Even")
        case .odd:
            return String(localized: "serial.open.parity.odd", defaultValue: "Odd")
        }
    }

    var summaryCode: String {
        switch self {
        case .none:
            return "N"
        case .even:
            return "E"
        case .odd:
            return "O"
        }
    }
}

enum SerialConsoleFlowControl: String, Codable, CaseIterable, Sendable {
    case none
    case hardware
    case software

    var localizedTitle: String {
        switch self {
        case .none:
            return String(localized: "serial.open.flowControl.none", defaultValue: "None")
        case .hardware:
            return String(localized: "serial.open.flowControl.hardware", defaultValue: "Hardware")
        case .software:
            return String(localized: "serial.open.flowControl.software", defaultValue: "Software")
        }
    }
}

enum SerialConsoleDataBits: Int, Codable, CaseIterable, Sendable {
    case five = 5
    case six = 6
    case seven = 7
    case eight = 8

    var title: String { String(rawValue) }
}

enum SerialConsoleStopBits: Int, Codable, CaseIterable, Sendable {
    case one = 1
    case two = 2

    var title: String { String(rawValue) }
}

struct SerialConsoleConfiguration: Codable, Equatable, Sendable {
    var devicePath: String
    var baudRate: Int
    var dataBits: SerialConsoleDataBits
    var stopBits: SerialConsoleStopBits
    var parity: SerialConsoleParity
    var flowControl: SerialConsoleFlowControl

    private enum CodingKeys: String, CodingKey {
        case devicePath
        case baudRate
        case dataBits
        case stopBits
        case parity
        case flowControl
    }

    init(
        devicePath: String,
        baudRate: Int = 115_200,
        dataBits: SerialConsoleDataBits = .eight,
        stopBits: SerialConsoleStopBits = .one,
        parity: SerialConsoleParity = .none,
        flowControl: SerialConsoleFlowControl = .none
    ) {
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.stopBits = stopBits
        self.parity = parity
        self.flowControl = flowControl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devicePath = try container.decode(String.self, forKey: .devicePath)
        baudRate = try container.decode(Int.self, forKey: .baudRate)

        let dataBitsRaw = try container.decodeIfPresent(Int.self, forKey: .dataBits)
        dataBits = dataBitsRaw.flatMap(SerialConsoleDataBits.init(rawValue:)) ?? .eight

        let stopBitsRaw = try container.decodeIfPresent(Int.self, forKey: .stopBits)
        stopBits = stopBitsRaw.flatMap(SerialConsoleStopBits.init(rawValue:)) ?? .one

        let parityRaw = try container.decodeIfPresent(String.self, forKey: .parity)
        parity = parityRaw.flatMap(SerialConsoleParity.init(rawValue:)) ?? .none

        let flowControlRaw = try container.decodeIfPresent(String.self, forKey: .flowControl)
        flowControl = flowControlRaw.flatMap(SerialConsoleFlowControl.init(rawValue:)) ?? .none
    }

    var trimmedDevicePath: String {
        devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var deviceLabel: String {
        let trimmed = trimmedDevicePath
        guard !trimmed.isEmpty else {
            return String(localized: "serial.panel.title.default", defaultValue: "Serial")
        }

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.isEmpty ? trimmed : lastPathComponent
    }

    var displayTitle: String {
        String.localizedStringWithFormat(
            String(localized: "serial.panel.title.format", defaultValue: "Serial %@"),
            deviceLabel
        )
    }

    var connectionSummary: String {
        "\(baudRate) \(dataBits.rawValue)\(parity.summaryCode)\(stopBits.rawValue)"
    }
}

enum SerialConsoleDefaults {
    static let baudRates: [Int] = [
        1_200,
        2_400,
        4_800,
        9_600,
        19_200,
        38_400,
        57_600,
        115_200,
        230_400,
    ]

    private static let devicePathKey = "serialConsole.devicePath"
    private static let baudRateKey = "serialConsole.baudRate"
    private static let dataBitsKey = "serialConsole.dataBits"
    private static let stopBitsKey = "serialConsole.stopBits"
    private static let parityKey = "serialConsole.parity"
    private static let flowControlKey = "serialConsole.flowControl"

    static func load(preferredDevicePath: String?) -> SerialConsoleConfiguration {
        let defaults = UserDefaults.standard
        let savedDevicePath = defaults.string(forKey: devicePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let devicePath = {
            if let savedDevicePath, !savedDevicePath.isEmpty {
                return savedDevicePath
            }
            return preferredDevicePath ?? ""
        }()

        let baudRate = {
            let value = defaults.integer(forKey: baudRateKey)
            return baudRates.contains(value) ? value : 115_200
        }()

        let dataBits = SerialConsoleDataBits(rawValue: defaults.integer(forKey: dataBitsKey)) ?? .eight
        let stopBits = SerialConsoleStopBits(rawValue: defaults.integer(forKey: stopBitsKey)) ?? .one
        let parity = defaults.string(forKey: parityKey)
            .flatMap(SerialConsoleParity.init(rawValue:)) ?? .none
        let flowControl = defaults.string(forKey: flowControlKey)
            .flatMap(SerialConsoleFlowControl.init(rawValue:)) ?? .none

        return SerialConsoleConfiguration(
            devicePath: devicePath,
            baudRate: baudRate,
            dataBits: dataBits,
            stopBits: stopBits,
            parity: parity,
            flowControl: flowControl
        )
    }

    static func save(_ configuration: SerialConsoleConfiguration) {
        let defaults = UserDefaults.standard
        defaults.set(configuration.trimmedDevicePath, forKey: devicePathKey)
        defaults.set(configuration.baudRate, forKey: baudRateKey)
        defaults.set(configuration.dataBits.rawValue, forKey: dataBitsKey)
        defaults.set(configuration.stopBits.rawValue, forKey: stopBitsKey)
        defaults.set(configuration.parity.rawValue, forKey: parityKey)
        defaults.set(configuration.flowControl.rawValue, forKey: flowControlKey)
    }
}

enum SerialConsoleDeviceDiscovery {
    static func availableDevicePaths(fileManager: FileManager = .default) -> [String] {
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: "/dev")
        } catch {
            return []
        }

        return entries
            .filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }
            .sorted(by: deviceSortKey(lhs:rhs:))
            .map { "/dev/\($0)" }
    }

    private static func deviceSortKey(lhs: String, rhs: String) -> Bool {
        let lhsRank = rank(for: lhs)
        let rhsRank = rank(for: rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func rank(for name: String) -> Int {
        if name.hasPrefix("cu.") {
            return 0
        }
        if name.hasPrefix("tty.") {
            return 1
        }
        return 2
    }
}

struct SerialConsoleConnectionError: LocalizedError, Sendable, Equatable {
    let detail: String

    var errorDescription: String? { detail }
}

@MainActor
final class SerialConsoleAccessoryView: NSView, NSTextFieldDelegate {
    private static let customDeviceMenuItemTag = -1

    private let discoveredDevicePaths: [String]
    private let deviceButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let devicePathField = NSTextField(frame: .zero)
    private let baudRateButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dataBitsButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stopBitsButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let parityButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let flowControlButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var grid: NSGridView = {
        let rows: [[NSView]] = [
            [Self.label(text: String(localized: "serial.open.device", defaultValue: "Device")), deviceButton],
            [Self.label(text: String(localized: "serial.open.devicePath", defaultValue: "Device Path")), devicePathField],
            [Self.label(text: String(localized: "serial.open.baudRate", defaultValue: "Baud Rate")), baudRateButton],
            [Self.label(text: String(localized: "serial.open.dataBits", defaultValue: "Data Bits")), dataBitsButton],
            [Self.label(text: String(localized: "serial.open.stopBits", defaultValue: "Stop Bits")), stopBitsButton],
            [Self.label(text: String(localized: "serial.open.parity", defaultValue: "Parity")), parityButton],
            [Self.label(text: String(localized: "serial.open.flowControl", defaultValue: "Flow Control")), flowControlButton],
        ]
        return NSGridView(views: rows)
    }()

    override var fittingSize: NSSize {
        layoutSubtreeIfNeeded()
        var size = grid.fittingSize
        size.width = max(size.width, 470)
        return size
    }

    override var intrinsicContentSize: NSSize {
        fittingSize
    }

    init(configuration: SerialConsoleConfiguration, discoveredDevicePaths: [String]) {
        self.discoveredDevicePaths = Self.uniqueDevicePaths(discoveredDevicePaths)
        super.init(frame: .zero)

        let initialDevicePath = configuration.trimmedDevicePath

        deviceButton.translatesAutoresizingMaskIntoConstraints = false
        deviceButton.target = self
        deviceButton.action = #selector(handleDeviceSelectionChanged(_:))
        rebuildDeviceMenu(selectedPath: initialDevicePath)

        devicePathField.translatesAutoresizingMaskIntoConstraints = false
        devicePathField.delegate = self
        devicePathField.stringValue = initialDevicePath

        baudRateButton.translatesAutoresizingMaskIntoConstraints = false
        for baudRate in SerialConsoleDefaults.baudRates {
            let item = NSMenuItem(title: String(baudRate), action: nil, keyEquivalent: "")
            item.tag = baudRate
            baudRateButton.menu?.addItem(item)
        }
        selectItem(withTag: configuration.baudRate, in: baudRateButton)

        dataBitsButton.translatesAutoresizingMaskIntoConstraints = false
        for dataBits in SerialConsoleDataBits.allCases {
            let item = NSMenuItem(title: dataBits.title, action: nil, keyEquivalent: "")
            item.tag = dataBits.rawValue
            dataBitsButton.menu?.addItem(item)
        }
        selectItem(withTag: configuration.dataBits.rawValue, in: dataBitsButton)

        stopBitsButton.translatesAutoresizingMaskIntoConstraints = false
        for stopBits in SerialConsoleStopBits.allCases {
            let item = NSMenuItem(title: stopBits.title, action: nil, keyEquivalent: "")
            item.tag = stopBits.rawValue
            stopBitsButton.menu?.addItem(item)
        }
        selectItem(withTag: configuration.stopBits.rawValue, in: stopBitsButton)

        parityButton.translatesAutoresizingMaskIntoConstraints = false
        for (index, parity) in SerialConsoleParity.allCases.enumerated() {
            let item = NSMenuItem(title: parity.localizedTitle, action: nil, keyEquivalent: "")
            item.tag = index
            parityButton.menu?.addItem(item)
        }
        parityButton.selectItem(at: max(0, SerialConsoleParity.allCases.firstIndex(of: configuration.parity) ?? 0))

        flowControlButton.translatesAutoresizingMaskIntoConstraints = false
        for (index, flowControl) in SerialConsoleFlowControl.allCases.enumerated() {
            let item = NSMenuItem(title: flowControl.localizedTitle, action: nil, keyEquivalent: "")
            item.tag = index
            flowControlButton.menu?.addItem(item)
        }
        flowControlButton.selectItem(at: max(0, SerialConsoleFlowControl.allCases.firstIndex(of: configuration.flowControl) ?? 0))

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        grid.xPlacement = .fill
        grid.yPlacement = .center

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            deviceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            devicePathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            baudRateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            dataBitsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            stopBitsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            parityButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            flowControlButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        invalidateIntrinsicContentSize()
        setFrameSize(fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedConfiguration: SerialConsoleConfiguration? {
        let devicePath = devicePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !devicePath.isEmpty else { return nil }

        let baudRate = baudRateButton.selectedItem?.tag ?? 115_200
        let dataBitsRaw = dataBitsButton.selectedItem?.tag ?? SerialConsoleDataBits.eight.rawValue
        let stopBitsRaw = stopBitsButton.selectedItem?.tag ?? SerialConsoleStopBits.one.rawValue
        let parityIndex = max(0, parityButton.indexOfSelectedItem)
        let flowControlIndex = max(0, flowControlButton.indexOfSelectedItem)

        return SerialConsoleConfiguration(
            devicePath: devicePath,
            baudRate: baudRate,
            dataBits: SerialConsoleDataBits(rawValue: dataBitsRaw) ?? .eight,
            stopBits: SerialConsoleStopBits(rawValue: stopBitsRaw) ?? .one,
            parity: SerialConsoleParity.allCases[safe: parityIndex] ?? .none,
            flowControl: SerialConsoleFlowControl.allCases[safe: flowControlIndex] ?? .none
        )
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === devicePathField else { return }
        syncDeviceSelection(with: devicePathField.stringValue)
    }

    private static func label(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.lineBreakMode = .byClipping
        return label
    }

    private static func uniqueDevicePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    @objc
    private func handleDeviceSelectionChanged(_ sender: NSPopUpButton) {
        guard let selectedItem = sender.selectedItem else { return }

        if selectedItem.tag == Self.customDeviceMenuItemTag {
            sender.window?.makeFirstResponder(devicePathField)
            return
        }

        guard let path = selectedItem.representedObject as? String else { return }
        devicePathField.stringValue = path
    }

    private func rebuildDeviceMenu(selectedPath: String) {
        deviceButton.removeAllItems()

        for path in discoveredDevicePaths {
            let item = NSMenuItem(title: path, action: nil, keyEquivalent: "")
            item.representedObject = path
            deviceButton.menu?.addItem(item)
        }

        if !discoveredDevicePaths.isEmpty {
            deviceButton.menu?.addItem(.separator())
        }

        let customItem = NSMenuItem(
            title: String(localized: "serial.open.device.custom", defaultValue: "Custom Device…"),
            action: nil,
            keyEquivalent: ""
        )
        customItem.tag = Self.customDeviceMenuItemTag
        deviceButton.menu?.addItem(customItem)

        syncDeviceSelection(with: selectedPath)
    }

    private func syncDeviceSelection(with devicePath: String) {
        let trimmedPath = devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            deviceButton.selectItem(withTag: Self.customDeviceMenuItemTag)
            return
        }

        if let matchingItem = deviceButton.itemArray.first(where: {
            ($0.representedObject as? String) == trimmedPath
        }) {
            deviceButton.select(matchingItem)
            return
        }

        deviceButton.selectItem(withTag: Self.customDeviceMenuItemTag)
    }

    private func selectItem(withTag tag: Int, in button: NSPopUpButton) {
        if button.selectItem(withTag: tag) {
            return
        }
        button.selectItem(at: 0)
    }
}

enum SerialConsoleOpenDialog {
    @MainActor
    static func present() -> SerialConsoleConfiguration? {
        let devicePaths = SerialConsoleDeviceDiscovery.availableDevicePaths()
        let configuration = SerialConsoleDefaults.load(preferredDevicePath: devicePaths.first)
        let accessoryView = SerialConsoleAccessoryView(
            configuration: configuration,
            discoveredDevicePaths: devicePaths
        )

        let alert = NSAlert()
        alert.messageText = String(localized: "serial.open.title", defaultValue: "Open Serial Console")
        alert.informativeText = String(
            localized: "serial.open.message",
            defaultValue: "Choose a serial device and line settings."
        )
        alert.addButton(withTitle: String(localized: "serial.open.confirm", defaultValue: "Open"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.accessoryView = accessoryView

        guard alert.runModal() == .alertFirstButtonReturn,
              let selectedConfiguration = accessoryView.selectedConfiguration else {
            return nil
        }

        SerialConsoleDefaults.save(selectedConfiguration)
        return selectedConfiguration
    }
}

final class SerialTerminalIO {
    private let configuration: SerialConsoleConfiguration
    private let ioQueue = DispatchQueue(label: "com.cmuxterm.serial")
    private let onReceiveData: (Data) -> Void
    private let onRuntimeMessage: (String) -> Void
    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var invalidated = false

    init(
        configuration: SerialConsoleConfiguration,
        onReceiveData: @escaping (Data) -> Void,
        onRuntimeMessage: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.onReceiveData = onReceiveData
        self.onRuntimeMessage = onRuntimeMessage
    }

    static func validate(configuration: SerialConsoleConfiguration) throws {
        let fileDescriptor = try openConfiguredFileDescriptor(for: configuration)
        close(fileDescriptor)
    }

    func activate() {
        ioQueue.async { [weak self] in
            self?.activateOnIOQueue()
        }
    }

    func invalidate() {
        ioQueue.async { [weak self] in
            self?.invalidateOnIOQueue()
        }
    }

    func write(_ bytes: UnsafePointer<CChar>, count: Int) {
        guard count > 0 else { return }
        let data = Data(bytes: bytes, count: count)
        ioQueue.async { [weak self] in
            self?.writeOnIOQueue(data)
        }
    }

    private func activateOnIOQueue() {
        guard !invalidated, fileDescriptor < 0 else { return }

        do {
            let configuredFileDescriptor = try Self.openConfiguredFileDescriptor(for: configuration)
            fileDescriptor = configuredFileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: configuredFileDescriptor, queue: ioQueue)
            source.setEventHandler { [weak self] in
                self?.handleReadableData()
            }
            source.setCancelHandler { [configuredFileDescriptor] in
                close(configuredFileDescriptor)
            }
            readSource = source
            source.resume()
        } catch {
            notifyRuntimeMessage(
                String.localizedStringWithFormat(
                    String(
                        localized: "serial.runtime.openFailed",
                        defaultValue: "Couldn't open %@: %@"
                    ),
                    configuration.trimmedDevicePath,
                    error.localizedDescription
                )
            )
        }
    }

    private func invalidateOnIOQueue() {
        guard !invalidated else { return }
        invalidated = true
        if let readSource {
            self.readSource = nil
            readSource.cancel()
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        fileDescriptor = -1
    }

    private func writeOnIOQueue(_ data: Data) {
        guard !invalidated, fileDescriptor >= 0 else { return }
        let writeError = data.withUnsafeBytes { rawBuffer -> String? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            var bytesWritten = 0

            while bytesWritten < rawBuffer.count, !invalidated {
                let remainingBytes = rawBuffer.count - bytesWritten
                let chunkBaseAddress = baseAddress.advanced(by: bytesWritten)
                let result = Darwin.write(fileDescriptor, chunkBaseAddress, remainingBytes)
                if result > 0 {
                    bytesWritten += result
                    continue
                }
                if result == -1, errno == EINTR {
                    continue
                }
                if result == 0 {
                    return String(cString: strerror(EIO))
                }
                return String(cString: strerror(errno))
            }

            return nil
        }
        if let writeError {
            notifyRuntimeMessage(
                String.localizedStringWithFormat(
                    String(
                        localized: "serial.runtime.writeFailed",
                        defaultValue: "Serial device write failed: %@"
                    ),
                    writeError
                )
            )
            invalidateOnIOQueue()
        }
    }

    private func handleReadableData() {
        guard !invalidated, fileDescriptor >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while !invalidated, fileDescriptor >= 0 {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[..<count])
                DispatchQueue.main.async { [onReceiveData] in
                    onReceiveData(data)
                }
                return
            }

            if count == 0 {
                notifyRuntimeMessage(
                    String(localized: "serial.runtime.disconnected", defaultValue: "Serial device disconnected.")
                )
                invalidateOnIOQueue()
                return
            }

            let errorCode = errno
            switch errorCode {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                return
            default:
                let detail = String(cString: strerror(errorCode))
                notifyRuntimeMessage(
                    String.localizedStringWithFormat(
                        String(
                            localized: "serial.runtime.readFailed",
                            defaultValue: "Serial device read failed: %@"
                        ),
                        detail
                    )
                )
                invalidateOnIOQueue()
                return
            }
        }
    }

    private func notifyRuntimeMessage(_ message: String) {
        DispatchQueue.main.async { [onRuntimeMessage] in
            onRuntimeMessage(message)
        }
    }

    private static func openConfiguredFileDescriptor(for configuration: SerialConsoleConfiguration) throws -> Int32 {
        let devicePath = configuration.trimmedDevicePath
        guard !devicePath.isEmpty else {
            throw SerialConsoleConnectionError(
                detail: String(localized: "serial.error.missingDevice", defaultValue: "Choose a serial device.")
            )
        }

        let fileDescriptor = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw SerialConsoleConnectionError(detail: String(cString: strerror(errno)))
        }

        do {
            try configure(fileDescriptor: fileDescriptor, with: configuration)
            return fileDescriptor
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    private static func configure(fileDescriptor: Int32, with configuration: SerialConsoleConfiguration) throws {
        var exclusive: Int32 = 0
        _ = Darwin.ioctl(fileDescriptor, TIOCEXCL, &exclusive)

        var attributes = termios()
        guard tcgetattr(fileDescriptor, &attributes) == 0 else {
            throw SerialConsoleConnectionError(detail: String(cString: strerror(errno)))
        }

        cfmakeraw(&attributes)
        attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
        attributes.c_cflag &= ~tcflag_t(CSIZE)

        switch configuration.dataBits {
        case .five:
            attributes.c_cflag |= tcflag_t(CS5)
        case .six:
            attributes.c_cflag |= tcflag_t(CS6)
        case .seven:
            attributes.c_cflag |= tcflag_t(CS7)
        case .eight:
            attributes.c_cflag |= tcflag_t(CS8)
        }

        if configuration.stopBits == .two {
            attributes.c_cflag |= tcflag_t(CSTOPB)
        } else {
            attributes.c_cflag &= ~tcflag_t(CSTOPB)
        }

        switch configuration.parity {
        case .none:
            attributes.c_cflag &= ~tcflag_t(PARENB | PARODD)
            attributes.c_iflag &= ~tcflag_t(INPCK)
        case .even:
            attributes.c_cflag |= tcflag_t(PARENB)
            attributes.c_cflag &= ~tcflag_t(PARODD)
            attributes.c_iflag |= tcflag_t(INPCK)
        case .odd:
            attributes.c_cflag |= tcflag_t(PARENB | PARODD)
            attributes.c_iflag |= tcflag_t(INPCK)
        }

        switch configuration.flowControl {
        case .none:
            attributes.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
            attributes.c_cflag &= ~tcflag_t(CRTSCTS)
        case .hardware:
            attributes.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
            attributes.c_cflag |= tcflag_t(CRTSCTS)
        case .software:
            attributes.c_iflag |= tcflag_t(IXON | IXOFF)
            attributes.c_iflag &= ~tcflag_t(IXANY)
            attributes.c_cflag &= ~tcflag_t(CRTSCTS)
        }

        guard let speed = baudRate(configuration.baudRate) else {
            throw SerialConsoleConnectionError(
                detail: String.localizedStringWithFormat(
                    String(
                        localized: "serial.error.unsupportedBaudRate",
                        defaultValue: "Unsupported baud rate: %lld"
                    ),
                    Int64(configuration.baudRate)
                )
            )
        }

        guard cfsetispeed(&attributes, speed) == 0,
              cfsetospeed(&attributes, speed) == 0 else {
            throw SerialConsoleConnectionError(detail: String(cString: strerror(errno)))
        }

        withUnsafeMutableBytes(of: &attributes.c_cc) { rawBuffer in
            rawBuffer[Int(VMIN)] = cc_t(1)
            rawBuffer[Int(VTIME)] = cc_t(0)
        }

        guard tcsetattr(fileDescriptor, TCSANOW, &attributes) == 0 else {
            throw SerialConsoleConnectionError(detail: String(cString: strerror(errno)))
        }

        _ = tcflush(fileDescriptor, TCIOFLUSH)

        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else {
            throw SerialConsoleConnectionError(detail: String(cString: strerror(errno)))
        }

        guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) >= 0 else {
            throw SerialConsoleConnectionError(detail: String(cString: strerror(errno)))
        }
    }

    private static func baudRate(_ rawValue: Int) -> speed_t? {
        switch rawValue {
        case 1_200:
            return speed_t(B1200)
        case 2_400:
            return speed_t(B2400)
        case 4_800:
            return speed_t(B4800)
        case 9_600:
            return speed_t(B9600)
        case 19_200:
            return speed_t(B19200)
        case 38_400:
            return speed_t(B38400)
        case 57_600:
            return speed_t(B57600)
        case 115_200:
            return speed_t(B115200)
        case 230_400:
            return speed_t(B230400)
        default:
            return nil
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
