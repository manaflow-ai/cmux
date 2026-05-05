import Darwin
import AppKit
import Foundation
import ObjectiveC

public final class CMUXSimulatorRuntime: @unchecked Sendable {
    public static let shared = CMUXSimulatorRuntime()
    public static let minimumXcodeMajor = 26

    private let deviceSetPath: String?
    private let inputLock = NSLock()
    private var inputSessions: [String: CMUXSimulatorHIDInput] = [:]

    public init(deviceSetPath: String? = nil) {
        self.deviceSetPath = deviceSetPath
    }

    public func listDevices() throws -> [CMUXSimulatorDevice] {
        try requireCapabilities()
        guard let set = resolveDeviceSet() else {
            throw CMUXSimulatorError.capabilityUnavailable("CoreSimulator device set is unavailable.")
        }
        return availableDevices(in: set).map(deviceSummary)
            .sorted { lhs, rhs in
                if lhs.runtime != rhs.runtime { return lhs.runtime < rhs.runtime }
                return lhs.name < rhs.name
            }
    }

    public func device(udid: String) throws -> CMUXSimulatorDevice {
        guard let device = try resolveDevice(udid: udid) else {
            throw CMUXSimulatorError.deviceNotFound(udid)
        }
        return deviceSummary(from: device)
    }

    public func boot(udid: String) throws {
        guard let device = try resolveDevice(udid: udid) else {
            throw CMUXSimulatorError.deviceNotFound(udid)
        }

        let bootWithOptions = NSSelectorFromString("bootWithOptions:error:")
        if device.responds(to: bootWithOptions) {
            var error: NSError?
            let options: NSDictionary = ["persist": true]
            if Self.invokeBoolWithObjectAndError(device, bootWithOptions, options, &error) {
                return
            }
        }

        let boot = NSSelectorFromString("bootWithError:")
        if device.responds(to: boot) {
            var error: NSError?
            if Self.invokeBoolWithError(device, boot, &error) {
                return
            }
        }

        throw CMUXSimulatorError.bootFailed("Failed to boot simulator \(udid).")
    }

    public func shutdown(udid: String) throws {
        guard let device = try resolveDevice(udid: udid) else {
            throw CMUXSimulatorError.deviceNotFound(udid)
        }
        let shutdown = NSSelectorFromString("shutdownWithError:")
        guard device.responds(to: shutdown) else {
            throw CMUXSimulatorError.shutdownFailed("CoreSimulator does not expose shutdownWithError:.")
        }
        var error: NSError?
        guard Self.invokeBoolWithError(device, shutdown, &error) else {
            throw CMUXSimulatorError.shutdownFailed(error?.localizedDescription ?? "Failed to shut down simulator \(udid).")
        }
    }

    public func screenStream(udid: String) throws -> CMUXSimulatorScreenStream {
        guard let device = try resolveDevice(udid: udid) else {
            throw CMUXSimulatorError.deviceNotFound(udid)
        }
        return CMUXSimulatorScreenStream(device: device)
    }

    public func performHardwareAction(_ action: CMUXSimulatorHardwareAction, udid: String) throws -> Bool {
        switch action {
        case .home, .lock:
            return try inputSession(udid: udid).sendButton(action)
        case .screenshot:
            let destination = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
                .appendingPathComponent("cmux-simulator-\(udid.prefix(8)).png")
            try runSimctl(["io", udid, "screenshot", destination.path])
            return true
        case .shake:
            try runSimctl(["spawn", udid, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"])
            return true
        case .volumeUp, .volumeDown, .rotateLeft, .rotateRight:
            throw CMUXSimulatorError.actionUnsupported("\(action.displayName) is not available through this SimulatorKit bridge yet.")
        }
    }

    public func openInSimulatorApp(udid: String) throws {
        try Self.runProcess(
            executable: "/usr/bin/open",
            arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        )
    }

    public func revealDeviceContainer(udid: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
            .appendingPathComponent(udid, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func installOrCopyFile(_ url: URL, udid: String) throws {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        if ext == "app" {
            try runSimctl(["install", udid, path])
            if let bundleID = Self.bundleIdentifier(in: url) {
                try runSimctl(["launch", udid, bundleID])
            }
            return
        }
        if ["png", "jpg", "jpeg", "heic", "mov", "mp4", "m4v"].contains(ext) {
            try runSimctl(["addmedia", udid, path])
            return
        }
        if ext == "mobileconfig" {
            try runSimctl(["openurl", udid, url.absoluteString])
            return
        }
        throw CMUXSimulatorError.actionUnsupported("Unsupported simulator drop: \(url.lastPathComponent)")
    }

    func inputSession(udid: String) throws -> CMUXSimulatorHIDInput {
        inputLock.lock()
        defer { inputLock.unlock() }
        if let session = inputSessions[udid] {
            return session
        }
        guard let device = try resolveDevice(udid: udid) else {
            throw CMUXSimulatorError.deviceNotFound(udid)
        }
        let session = CMUXSimulatorHIDInput(device: device, simulatorKitPath: Self.simulatorKitPath())
        inputSessions[udid] = session
        return session
    }

    func resolveDevice(udid: String) throws -> NSObject? {
        try requireCapabilities()
        guard let set = resolveDeviceSet() else { return nil }
        return availableDevices(in: set).first { device in
            ((device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? "") == udid
        }
    }

    public static func probeCapabilities() -> CMUXSimulatorCapabilityReport {
        var failures: [String] = []
        let developerDir = developerDirectory()
        let xcodeMajor = xcodeMajorVersion()
        if let xcodeMajor {
            if xcodeMajor < minimumXcodeMajor {
                failures.append("Xcode \(minimumXcodeMajor)+ is required for SimulatorKit preview HID; found Xcode \(xcodeMajor).")
            }
        } else {
            failures.append("Unable to determine the active Xcode version.")
        }

        failures.append(contentsOf: loadFrameworks())

        if NSClassFromString("SimServiceContext") == nil {
            failures.append("CoreSimulator class SimServiceContext is unavailable.")
        }
        if NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") == nil,
           findHIDClientClass() == nil {
            failures.append("SimulatorKit HID client class is unavailable.")
        }

        if let handle = dlopen(simulatorKitPath(), RTLD_NOW | RTLD_GLOBAL) {
            for symbol in [
                "IndigoHIDMessageForMouseNSEvent",
                "IndigoHIDMessageForButton",
                "IndigoHIDMessageForScrollEvent"
            ] where dlsym(handle, symbol) == nil {
                failures.append("SimulatorKit symbol \(symbol) is unavailable.")
            }
        }

        return CMUXSimulatorCapabilityReport(
            xcodeMajorVersion: xcodeMajor,
            minimumXcodeMajorVersion: minimumXcodeMajor,
            developerDirectory: developerDir,
            failures: failures
        )
    }

    private func requireCapabilities() throws {
        let report = Self.probeCapabilities()
        guard report.isUsable else {
            throw CMUXSimulatorError.capabilityUnavailable(report.failureSummary ?? "Simulator runtime is unavailable.")
        }
    }

    private func resolveDeviceSet() -> NSObject? {
        guard let contextClass = NSClassFromString("SimServiceContext") else {
            return nil
        }
        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        var contextError: NSError?
        guard let context = Self.invokeClassObjectWithObjectAndError(
            contextClass,
            contextSelector,
            Self.developerDirectory() as NSString,
            &contextError
        ) else {
            return nil
        }

        if let deviceSetPath,
           let custom = customDeviceSet(context: context, path: deviceSetPath) {
            return custom
        }

        let defaultSet = NSSelectorFromString("defaultDeviceSetWithError:")
        var setError: NSError?
        return Self.invokeObjectWithError(context, defaultSet, &setError)
    }

    private func customDeviceSet(context: NSObject, path: String) -> NSObject? {
        let selector = NSSelectorFromString("deviceSetWithPath:error:")
        guard context.responds(to: selector) else { return nil }
        let candidates = [path, (path as NSString).appendingPathComponent("Devices")]
        for candidate in candidates where Self.isDirectory(candidate) {
            var error: NSError?
            if let set = Self.invokeObjectWithObjectAndError(context, selector, candidate as NSString, &error),
               !availableDevices(in: set).isEmpty {
                return set
            }
        }
        return nil
    }

    private func availableDevices(in set: NSObject) -> [NSObject] {
        (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
    }

    private func deviceSummary(from device: NSObject) -> CMUXSimulatorDevice {
        let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
        let name = (device.value(forKey: "name") as? String) ?? "Unknown"
        let rawState = (device.value(forKey: "state") as? NSNumber)?.uintValue ?? UInt.max
        let runtime = (device.value(forKey: "runtime") as? NSObject).flatMap { runtime in
            (runtime.value(forKey: "name") as? String) ??
                (runtime.value(forKey: "versionString") as? String) ??
                (runtime.value(forKey: "identifier") as? String)
        } ?? ""

        let deviceType = device.value(forKey: "deviceType") as? NSObject
        let pointsValue = deviceType?.value(forKey: "mainScreenSize") as? NSValue
        let pointSize = pointsValue?.sizeValue ?? .zero
        let scale = (deviceType?.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue ?? 0
        let pixelSize = scale > 0
            ? CMUXSimulatorSize(width: pointSize.width * scale, height: pointSize.height * scale)
            : .zero

        return CMUXSimulatorDevice(
            udid: udid,
            name: name,
            state: Self.state(rawState),
            runtime: runtime,
            screenSizePoints: CMUXSimulatorSize(width: pointSize.width, height: pointSize.height),
            screenSizePixels: pixelSize
        )
    }

    private static func state(_ raw: UInt) -> CMUXSimulatorState {
        switch raw {
        case 0: return .creating
        case 1: return .shutdown
        case 2: return .booting
        case 3: return .booted
        case 4: return .shuttingDown
        default: return .unknown
        }
    }

    private static func bundleIdentifier(in appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        return bundle.bundleIdentifier
    }

    private func runSimctl(_ arguments: [String]) throws {
        try Self.runProcess(executable: "/usr/bin/xcrun", arguments: ["simctl"] + arguments)
    }

    private static func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw CMUXSimulatorError.processFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CMUXSimulatorError.processFailed(message ?? "\(executable) exited \(process.terminationStatus)")
        }
    }
}

extension CMUXSimulatorRuntime {
    nonisolated(unsafe) private static var frameworkLoadLock = NSLock()
    nonisolated(unsafe) private static var frameworkLoadFailures: [String]?

    static func loadFrameworks() -> [String] {
        frameworkLoadLock.lock()
        defer { frameworkLoadLock.unlock() }
        if let frameworkLoadFailures {
            return frameworkLoadFailures
        }

        var failures: [String] = []
        for path in coreSimulatorPaths() where FileManager.default.fileExists(atPath: path) {
            if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
                break
            }
        }
        if NSClassFromString("SimServiceContext") == nil {
            failures.append("Failed to load CoreSimulator.framework: \(dlerrorDescription()).")
        }

        let simulatorKit = simulatorKitPath()
        if dlopen(simulatorKit, RTLD_NOW | RTLD_GLOBAL) == nil {
            failures.append("Failed to load SimulatorKit.framework at \(simulatorKit): \(dlerrorDescription()).")
        }

        frameworkLoadFailures = failures
        return failures
    }

    static func developerDirectory() -> String {
        if let selected = xcodeSelectDeveloperDirectory(), hasSimulatorKit(at: selected) {
            return selected
        }
        let canonical = "/Applications/Xcode.app/Contents/Developer"
        if hasSimulatorKit(at: canonical) {
            return canonical
        }
        let applications = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for app in applications.sorted()
        where app.hasPrefix("Xcode") && app.hasSuffix(".app") {
            let developer = "/Applications/\(app)/Contents/Developer"
            if hasSimulatorKit(at: developer) {
                return developer
            }
        }
        return selectedDeveloperDirectoryFallback()
    }

    static func simulatorKitPath() -> String {
        (developerDirectory() as NSString)
            .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")
    }

    static func findHIDClientClass() -> AnyClass? {
        if let canonical = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") {
            return canonical
        }

        let selector = NSSelectorFromString("initWithDevice:error:")
        let expectedSuffixes = [
            "SimDeviceLegacyHIDClient",
            "HIDClient"
        ]

        let count = objc_getClassList(nil, 0)
        guard count > 0 else { return nil }
        let classes = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(count))
        defer { classes.deallocate() }
        let actualCount = objc_getClassList(AutoreleasingUnsafeMutablePointer(classes), count)
        guard actualCount > 0 else { return nil }

        for index in 0..<Int(actualCount) {
            guard let candidate = classes[index] else { continue }
            let name = NSStringFromClass(candidate)
            guard expectedSuffixes.contains(where: { name.hasSuffix($0) }) else { continue }
            if class_getInstanceMethod(candidate, selector) != nil {
                return candidate
            }
        }
        return nil
    }

    private static func coreSimulatorPaths() -> [String] {
        [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            (developerDirectory() as NSString)
                .appendingPathComponent("Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator")
        ]
    }

    private static func xcodeSelectDeveloperDirectory() -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func selectedDeveloperDirectoryFallback() -> String {
        xcodeSelectDeveloperDirectory() ?? "/Applications/Xcode.app/Contents/Developer"
    }

    private static func hasSimulatorKit(at developerDirectory: String) -> Bool {
        let path = (developerDirectory as NSString)
            .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")
        return FileManager.default.fileExists(atPath: path)
    }

    private static func xcodeMajorVersion() -> Int? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-version"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let firstLine = output.split(separator: "\n").first ?? ""
        let components = firstLine.split(separator: " ")
        guard components.count >= 2 else { return nil }
        let version = components[1].split(separator: ".").first.map(String.init)
        return version.flatMap(Int.init)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func dlerrorDescription() -> String {
        guard let error = dlerror() else { return "unknown dlopen error" }
        return String(cString: error)
    }

    static func invokeBoolWithError(_ target: NSObject, _ selector: Selector, _ error: inout NSError?) -> Bool {
        guard let implementation = class_getMethodImplementation(type(of: target), selector) else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> Bool
        return unsafeBitCast(implementation, to: Function.self)(target, selector, &error)
    }

    static func invokeBoolWithObjectAndError(
        _ target: NSObject,
        _ selector: Selector,
        _ object: AnyObject,
        _ error: inout NSError?
    ) -> Bool {
        guard let implementation = class_getMethodImplementation(type(of: target), selector) else {
            return false
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> Bool
        return unsafeBitCast(implementation, to: Function.self)(target, selector, object, &error)
    }

    static func invokeObjectWithError(_ target: NSObject, _ selector: Selector, _ error: inout NSError?) -> NSObject? {
        guard let implementation = class_getMethodImplementation(type(of: target), selector) else {
            return nil
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        return unsafeBitCast(implementation, to: Function.self)(target, selector, &error) as? NSObject
    }

    static func invokeObjectWithObjectAndError(
        _ target: NSObject,
        _ selector: Selector,
        _ object: AnyObject,
        _ error: inout NSError?
    ) -> NSObject? {
        guard let implementation = class_getMethodImplementation(type(of: target), selector) else {
            return nil
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        return unsafeBitCast(implementation, to: Function.self)(target, selector, object, &error) as? NSObject
    }

    static func invokeClassObjectWithObjectAndError(
        _ target: AnyClass,
        _ selector: Selector,
        _ object: AnyObject,
        _ error: inout NSError?
    ) -> NSObject? {
        guard let metaClass = object_getClass(target),
              let implementation = class_getMethodImplementation(metaClass, selector) else {
            return nil
        }
        typealias Function = @convention(c) (
            AnyClass,
            Selector,
            AnyObject,
            AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        return unsafeBitCast(implementation, to: Function.self)(target, selector, object, &error) as? NSObject
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
