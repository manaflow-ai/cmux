//
//  ContentView.swift
//  SampleSidebarExtensionApp
//
//  Created by Abdulaziz Albahar on 5/29/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(String(localized: "sampleSidebarApp.title", defaultValue: "CMUX Sample Sidebar Extension"))
                .font(.title2.weight(.semibold))
            Text(String(
                localized: "sampleSidebarApp.detail",
                defaultValue: "Keep this app installed. In cmux, click the puzzle button, choose Manage Sidebar Extensions..., enable CMUX Sample Sidebar Extension, choose Extension Sidebar, and confirm Workspace Signals appears."
            ))
            .foregroundStyle(.secondary)
            Text(String(
                localized: "sampleSidebarApp.identifier",
                defaultValue: "Extension ID: co.manaflow.CMUXExtKitSampleSidebarApp.Extension"
            ))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            Text(String(
                localized: "sampleSidebarApp.scopes",
                defaultValue: "Requests workspace metadata, paths, notifications, ports, and pull request links."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
