//
//  AcknowledgmentsView.swift
//  cmux
//
//  Created by Gale Williams on 3/16/26.
//

import SwiftUI

// MARK: - AcknowledgmentsView

struct AcknowledgmentsView: View {
    // MARK: Properties

    private let content: String = {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md"),
           let text = try? String(contentsOf: url)
        {
            return text
        }
        return String(localized: "about.licenses.notFound", defaultValue: "Licenses file not found.")
    }()

    // MARK: Content Properties

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
