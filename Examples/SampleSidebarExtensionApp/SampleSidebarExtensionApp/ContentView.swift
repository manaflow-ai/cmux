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
                defaultValue: "Keep this app installed, then open cmux, use the sidebar puzzle button, choose Manage Extensions, enable this extension, and choose the extension sidebar."
            ))
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
