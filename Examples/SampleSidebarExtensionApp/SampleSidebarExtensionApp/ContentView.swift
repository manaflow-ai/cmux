//
//  ContentView.swift
//  SampleSidebarExtensionApp
//
//  Created by Abdulaziz Albahar on 5/29/26.
//

import AppKit

@MainActor
final class ContentViewController: NSViewController {
    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "puzzlepiece.extension",
            accessibilityDescription: String(localized: "sampleSidebarApp.title", defaultValue: "CMUX Sample Sidebar Extension")
        ) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label(
            String(localized: "sampleSidebarApp.title", defaultValue: "CMUX Sample Sidebar Extension"),
            font: .systemFont(ofSize: 17, weight: .semibold)
        ))
        stack.addArrangedSubview(label(String(
            localized: "sampleSidebarApp.detail",
            defaultValue: "Keep this app installed. In cmux, open Sidebar Extensions, enable CMUX Sample Sidebar Extension, choose it from the sidebar picker, and confirm Workspace Signals shows your real workspaces."
        )))
        stack.addArrangedSubview(label(
            String(
                localized: "sampleSidebarApp.identifier",
                defaultValue: "Extension ID: co.manaflow.CMUXExtKitSampleSidebarApp.Extension"
            ),
            font: .monospacedSystemFont(ofSize: 11, weight: .regular)
        ))
        stack.addArrangedSubview(label(
            String(
                localized: "sampleSidebarApp.scopes",
                defaultValue: "Requests workspace and surface metadata, plus navigation, selection, and create-surface actions for the sidebar controls."
            ),
            font: .systemFont(ofSize: 11)
        ))

        view = stack
        view.widthAnchor.constraint(equalToConstant: 420).isActive = true
    }

    private func label(
        _ text: String,
        font: NSFont = .systemFont(ofSize: 13)
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = font.pointSize >= 17 ? .labelColor : .secondaryLabelColor
        field.maximumNumberOfLines = 0
        return field
    }
}
