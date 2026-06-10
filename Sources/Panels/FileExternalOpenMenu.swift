import AppKit
import AVKit
import Bonsplit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers


// MARK: - External Open Menu
enum FileExternalOpenMenuFactory {
    static func makeMenu(
        fileURL: URL,
        primaryApplication: FileExternalOpenApplication?,
        otherApplications: [FileExternalOpenApplication]
    ) -> NSMenu {
        let menu = NSMenu(title: FileExternalOpenText.openWithMenu)
        menu.autoenablesItems = false

        if let primaryApplication {
            menu.addItem(menuItem(
                title: FileExternalOpenText.openInApplication(primaryApplication.displayName),
                fileURL: fileURL,
                action: .open(applicationURL: primaryApplication.url)
            ))
        } else {
            menu.addItem(menuItem(
                title: FileExternalOpenText.openExternally,
                fileURL: fileURL,
                action: .open(applicationURL: nil)
            ))
        }

        menu.addItem(menuItem(
            title: FileExternalOpenText.revealInFinder,
            fileURL: fileURL,
            action: .revealInFinder
        ))

        if !otherApplications.isEmpty {
            menu.addItem(.separator())
            let openWithMenu = NSMenu(title: FileExternalOpenText.openWithMenu)
            openWithMenu.autoenablesItems = false
            for application in otherApplications {
                openWithMenu.addItem(menuItem(
                    title: application.displayName,
                    fileURL: fileURL,
                    action: .open(applicationURL: application.url)
                ))
            }
            let openWithItem = NSMenuItem(
                title: FileExternalOpenText.openWithMenu,
                action: nil,
                keyEquivalent: ""
            )
            openWithItem.submenu = openWithMenu
            menu.addItem(openWithItem)
        }

        return menu
    }

    private static func menuItem(
        title: String,
        fileURL: URL,
        action: FileExternalOpenMenuPayloadAction
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(FileExternalOpenMenuActionTarget.open(_:)),
            keyEquivalent: ""
        )
        item.target = FileExternalOpenMenuActionTarget.shared
        item.representedObject = FileExternalOpenMenuActionPayload(
            fileURL: fileURL,
            action: action
        )
        return item
    }
}

enum FileExternalOpenMenuStyle {
    case header
    case chrome

    var buttonSize: CGSize {
        switch self {
        case .header:
            return CGSize(width: 18, height: 18)
        case .chrome:
            return CGSize(width: 40, height: 40)
        }
    }
}

struct FileExternalOpenMenu: View {
    let fileURL: URL
    var isDisabled = false
    var style: FileExternalOpenMenuStyle = .header

    @State private var resolvedApplications: [FileExternalOpenApplication] = []

    var body: some View {
        let applications = resolvedApplications
        let primaryApplication = primaryApplication(in: applications)
        let otherApplications = applications.filter { application in
            application.id != primaryApplication?.id
        }
        let helpText = helpText(for: primaryApplication)

        Group {
            switch style {
            case .header:
                FileExternalOpenHeaderMenuButton(
                    fileURL: fileURL,
                    primaryApplication: primaryApplication,
                    otherApplications: otherApplications,
                    helpText: helpText,
                    isDisabled: isDisabled
                )
            case .chrome:
                Button {
                    presentMenu(
                        applications: applications,
                        currentPrimaryApplication: primaryApplication,
                        otherApplications: otherApplications
                    )
                } label: {
                    label
                }
                .contentShape(Rectangle())
                .disabled(isDisabled)
                .help(helpText)
                .accessibilityLabel(helpText)
            }
        }
        .task(id: fileURL) {
            await refreshApplications()
        }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .header:
            PanelHeaderIconGlyph(systemName: "square.and.arrow.up")
        case .chrome:
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: style.buttonSize.width, height: style.buttonSize.height)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
    }

    private func primaryApplication(in applications: [FileExternalOpenApplication]) -> FileExternalOpenApplication? {
        applications.first { $0.isDefault } ?? applications.first
    }

    private func helpText(for primaryApplication: FileExternalOpenApplication?) -> String {
        if let primaryApplication {
            return openInTitle(primaryApplication.displayName)
        }
        return FileExternalOpenText.openExternally
    }

    private func openInTitle(_ applicationName: String) -> String {
        FileExternalOpenText.openInApplication(applicationName)
    }

    @MainActor
    private func refreshApplications() async {
        resolvedApplications = []
        let url = fileURL
        let applications = await Task.detached(priority: .userInitiated) {
            FileExternalOpenApplicationResolver.live.applications(for: url)
        }.value
        guard !Task.isCancelled else { return }
        resolvedApplications = applications
    }

    private func presentMenu(
        applications: [FileExternalOpenApplication],
        currentPrimaryApplication: FileExternalOpenApplication?,
        otherApplications: [FileExternalOpenApplication]
    ) {
        guard !isDisabled else { return }
        let menuApplications: [FileExternalOpenApplication]
        if applications.isEmpty {
            menuApplications = FileExternalOpenApplicationResolver.live.applications(for: fileURL)
        } else {
            menuApplications = applications
        }
        let primary = primaryApplication(in: menuApplications) ?? currentPrimaryApplication
        let others = menuApplications.filter { application in
            application.id != primary?.id
        } + otherApplications.filter { application in
            application.id != primary?.id
                && !menuApplications.contains(where: { $0.id == application.id })
        }
        let menu = makeMenu(primaryApplication: primary, otherApplications: others)
        if let event = NSApp.currentEvent, let contentView = event.window?.contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil as NSMenuItem?, at: point, in: contentView)
        } else {
            menu.popUp(positioning: nil as NSMenuItem?, at: NSEvent.mouseLocation, in: nil as NSView?)
        }
    }

    private func makeMenu(
        primaryApplication: FileExternalOpenApplication?,
        otherApplications: [FileExternalOpenApplication]
    ) -> NSMenu {
        FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: primaryApplication,
            otherApplications: otherApplications
        )
    }
}

private struct FileExternalOpenHeaderMenuButton: View {
    let fileURL: URL
    let primaryApplication: FileExternalOpenApplication?
    let otherApplications: [FileExternalOpenApplication]
    let helpText: String
    let isDisabled: Bool

    var body: some View {
        Button(action: presentMenu) {
            PanelHeaderIconGlyph(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private func presentMenu() {
        let menu = makeMenu()
        if let event = NSApp.currentEvent,
           let contentView = event.window?.contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil as NSMenuItem?, at: point, in: contentView)
            return
        }

        guard let contentView = NSApp.keyWindow?.contentView else { return }
        menu.popUp(
            positioning: nil as NSMenuItem?,
            at: NSPoint(x: contentView.bounds.maxX - 24, y: contentView.bounds.maxY - 32),
            in: contentView
        )
    }

    private func makeMenu() -> NSMenu {
        FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: primaryApplication,
            otherApplications: otherApplications
        )
    }
}

private enum FileExternalOpenMenuPayloadAction {
    case open(applicationURL: URL?)
    case revealInFinder
}

private final class FileExternalOpenMenuActionPayload: NSObject {
    let fileURL: URL
    let action: FileExternalOpenMenuPayloadAction

    init(fileURL: URL, action: FileExternalOpenMenuPayloadAction) {
        self.fileURL = fileURL
        self.action = action
    }
}

private final class FileExternalOpenMenuActionTarget: NSObject {
    static let shared = FileExternalOpenMenuActionTarget()

    @objc func open(_ item: NSMenuItem) {
        guard let payload = item.representedObject as? FileExternalOpenMenuActionPayload else {
            return
        }
        switch payload.action {
        case .open(let applicationURL):
            guard let applicationURL else {
                FileExternalOpenAction.openDefault(fileURL: payload.fileURL)
                return
            }
            FileExternalOpenAction.open(fileURL: payload.fileURL, applicationURL: applicationURL)
        case .revealInFinder:
            FileExternalOpenAction.revealInFinder(fileURL: payload.fileURL)
        }
    }
}

