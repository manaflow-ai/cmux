import AppKit
import CmuxSimulator
import Foundation

actor SimulatorDeviceChromeLoader {
    private let deviceTypeRoots: [URL]
    private let chromeRoots: [URL]
    private let fileManager: FileManager
    private let measurer: SimulatorDeviceChromeMeasurer
    private var cache: [String: SimulatorDeviceChromeProfile?] = [:]

    init(
        deviceTypeRoots: [URL]? = nil,
        chromeRoots: [URL]? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        developerSelectionURL: URL = URL(
            fileURLWithPath: "/var/db/xcode_select_link",
            isDirectory: true
        ),
        measurer: SimulatorDeviceChromeMeasurer = SimulatorDeviceChromeMeasurer()
    ) {
        self.fileManager = fileManager
        self.measurer = measurer
        let developerDirectory = activeSimulatorDeveloperDirectory(
            environment: environment,
            selectionURL: developerSelectionURL,
            fileManager: fileManager
        )
        self.deviceTypeRoots = deviceTypeRoots
            ?? defaultSimulatorDeviceTypeRoots(developerDirectory: developerDirectory)
        self.chromeRoots = chromeRoots
            ?? defaultSimulatorChromeRoots(developerDirectory: developerDirectory)
    }

    func load(deviceTypeIdentifier: String) -> SimulatorDeviceChromeProfile? {
        if let cached = cache[deviceTypeIdentifier] { return cached }
        let loaded = loadUncached(deviceTypeIdentifier: deviceTypeIdentifier)
        cache[deviceTypeIdentifier] = loaded
        return loaded
    }

    private func loadUncached(deviceTypeIdentifier: String) -> SimulatorDeviceChromeProfile? {
        guard let bundleURL = findDeviceType(identifier: deviceTypeIdentifier),
              let profile = dictionary(at: bundleURL.appendingPathComponent("Contents/Resources/profile.plist")),
              let chromeIdentifier = profile["chromeIdentifier"] as? String,
              let rawWidth = number(profile["mainScreenWidth"]),
              let rawHeight = number(profile["mainScreenHeight"]),
              let scale = number(profile["mainScreenScale"]), scale > 0,
              let chromeResources = findChromeResources(identifier: chromeIdentifier),
              let data = try? Data(contentsOf: chromeResources.appendingPathComponent("chrome.json")),
              let chrome = try? JSONDecoder().decode(SimulatorDeviceChrome.self, from: data) else {
            return nil
        }

        let screenWidth = rawWidth / scale
        let screenHeight = rawHeight / scale
        var leading = chrome.images.sizing.leftWidth
        var trailing = chrome.images.sizing.rightWidth
        var top = chrome.images.sizing.topHeight
        var bottom = chrome.images.sizing.bottomHeight
        let compositeURL = resourceURL(named: chrome.images.composite, in: chromeResources)
        if let compositeURL, let image = NSImage(contentsOf: compositeURL),
           image.size.width > screenWidth, image.size.height > screenHeight {
            leading = (image.size.width - screenWidth) / 2
            trailing = image.size.width - screenWidth - leading
            bottom = (image.size.height - screenHeight) / 2
            top = image.size.height - screenHeight - bottom
        }

        let bodyWidth = screenWidth + leading + trailing
        let bodyHeight = screenHeight + top + bottom
        let padding = chrome.images.devicePadding ?? .zero
        let outerHeight = bodyHeight + padding.top + padding.bottom
        let assets = chrome.images.assetNames.reduce(into: [String: URL]()) { result, entry in
            if let url = resourceURL(named: entry.value, in: chromeResources) {
                result[entry.key] = url
            }
        }
        let fallbackScreenRadius = max(
            chrome.paths.simpleOutsideBorder.cornerRadiusX - max(
                chrome.images.sizing.leftWidth,
                chrome.images.sizing.topHeight
            ),
            0
        )
        let screenCornerRadius = compositeURL
            .flatMap(measurer.screenOpening)
            .map { opening in
                max(0, opening.radius - ((opening.width - screenWidth) / 2))
            } ?? fallbackScreenRadius
        let buttons = chrome.inputs.compactMap { input -> SimulatorDeviceChromeProfile.Button? in
            guard let imageURL = resourceURL(named: input.image, in: chromeResources),
                  let image = NSImage(contentsOf: imageURL) else { return nil }
            let width = max(Double(image.size.width), 12)
            let height = max(Double(image.size.height), 12)
            let normal = input.offsets.normal ?? input.offsets.rollover ?? .zero
            let rollover = input.offsets.rollover ?? normal
            let restX = (2 * normal.x) - rollover.x
            let restY = (2 * normal.y) - rollover.y
            let alignedX: Double
            switch input.align {
            case "trailing": alignedX = padding.left + bodyWidth + restX - width
            case "center": alignedX = padding.left + ((bodyWidth - width) / 2) + restX
            default: alignedX = padding.left + restX
            }
            let topLeft: SimulatorDeviceChromePoint
            switch input.anchor {
            case "left":
                topLeft = .init(
                    x: padding.left + rollover.x - (width / 2),
                    y: padding.top + rollover.y
                )
            case "right":
                topLeft = .init(
                    x: padding.left + bodyWidth + restX,
                    y: padding.top + restY
                )
            case "top":
                topLeft = .init(x: alignedX, y: padding.top + restY - height)
            case "bottom":
                topLeft = .init(x: alignedX, y: padding.top + bodyHeight + restY)
            default:
                return nil
            }
            return SimulatorDeviceChromeProfile.Button(
                name: input.name,
                rect: SimulatorRect(
                    x: topLeft.x - 4,
                    y: outerHeight - topLeft.y - height - 4,
                    width: width + 8,
                    height: height + 8
                ),
                imageURL: imageURL,
                imageDownURL: resourceURL(named: input.imageDown, in: chromeResources),
                onTop: input.onTop ?? false,
                normalOffset: .init(x: normal.x, y: normal.y),
                rolloverOffset: .init(x: rollover.x, y: rollover.y),
                usagePage: input.usagePage,
                usage: input.usage
            )
        }
        return SimulatorDeviceChromeProfile(
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            insets: .init(
                top: top + padding.top,
                leading: leading + padding.left,
                bottom: bottom + padding.bottom,
                trailing: trailing + padding.right
            ),
            devicePadding: .init(
                top: padding.top,
                leading: padding.left,
                bottom: padding.bottom,
                trailing: padding.right
            ),
            cornerRadius: chrome.paths.simpleOutsideBorder.cornerRadiusX,
            screenCornerRadius: screenCornerRadius,
            assets: assets,
            compositeURL: compositeURL,
            buttons: buttons
        )
    }

    private func findDeviceType(identifier: String) -> URL? {
        for root in deviceTypeRoots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "simdevicetype" {
                guard let info = dictionary(at: entry.appendingPathComponent("Contents/Info.plist")),
                      info["CFBundleIdentifier"] as? String == identifier else { continue }
                return entry
            }
        }
        return nil
    }

    private func findChromeResources(identifier: String) -> URL? {
        let suffix = identifier.split(separator: ".").last.map(String.init) ?? identifier
        for root in chromeRoots {
            let resources = root
                .appendingPathComponent("\(suffix).devicechrome", isDirectory: true)
                .appendingPathComponent("Contents/Resources", isDirectory: true)
            if fileManager.fileExists(atPath: resources.path) { return resources }
        }
        return nil
    }

    private func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        return value as? [String: Any]
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func resourceURL(named name: String?, in directory: URL) -> URL? {
        guard let name else { return nil }
        for fileExtension in ["pdf", "png", "tiff"] {
            let url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

}

private func activeSimulatorDeveloperDirectory(
    environment: [String: String],
    selectionURL: URL,
    fileManager: FileManager
) -> URL? {
    if let override = environment["DEVELOPER_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let selection = selectionURL.resolvingSymlinksInPath()
    return fileManager.fileExists(atPath: selection.path) ? selection : nil
}

private func defaultSimulatorDeviceTypeRoots(developerDirectory: URL?) -> [URL] {
    var roots = [
        URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes", isDirectory: true),
    ]
    if let developerDirectory {
        roots.insert(
            developerDirectory.appendingPathComponent(
                "Platforms/iPhoneSimulator.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes",
                isDirectory: true
            ),
            at: 0
        )
        roots.insert(
            developerDirectory.appendingPathComponent(
                "Library/Developer/CoreSimulator/Profiles/DeviceTypes",
                isDirectory: true
            ),
            at: 0
        )
    }
    return roots
}

private func defaultSimulatorChromeRoots(developerDirectory: URL?) -> [URL] {
    var roots = [
        URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome", isDirectory: true),
    ]
    if let developerDirectory {
        roots.insert(
            developerDirectory.appendingPathComponent(
                "Library/Developer/DeviceKit/Chrome",
                isDirectory: true
            ),
            at: 0
        )
    }
    return roots
}
