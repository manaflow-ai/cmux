#if DEBUG
import SwiftUI

struct SpinnerCard: View {
    let spec: SpinnerSpec

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                spec.makeView()
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(spec.title)
                        .font(.system(size: 12, weight: .semibold))
                    if spec.shipping {
                        Text("IN SIDEBAR")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.6)
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    Spacer()
                    Text(spec.energy.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(spec.energy.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(spec.energy.color.opacity(0.15)))
                }
                Text(spec.mechanism)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}
#endif
