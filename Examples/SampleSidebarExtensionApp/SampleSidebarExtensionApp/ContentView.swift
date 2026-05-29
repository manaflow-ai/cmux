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
                defaultValue: "Install this app, then choose CMUX Extensions from the cmux sidebar selector to host the extension."
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
