HSplitView {
  // LEFT COLUMN: machine telemetry
  VStack(alignment: .leading, spacing: 10) {
    HStack(spacing: 6) {
      Image(systemName: "cpu")
      Text("MACHINE").font(.caption).bold().foregroundColor("#8b95a5")
      Spacer()
      Text(clock.time).font(.caption).foregroundColor("#8b95a5")
    }

    // Per-GPU gauges
    ForEach(gpus) { gpu in
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text("GPU \(gpu.index)").font(.caption).bold()
          Text(gpu.name).font(.caption).foregroundColor("#8b95a5")
          Spacer()
          Text("\(gpu.tempC)°C")
            .font(.caption)
            .foregroundColor(gpu.tempC >= 84 ? "#ff5c5c" : "#8b95a5")
        }
        // utilization bar
        HStack(spacing: 2) {
          for seg in 0..<20 {
            Text("▉")
              .font(.caption)
              .foregroundColor(seg < gpu.utilPct / 5
                ? (gpu.utilPct >= 95 ? "#3ddc84" : "#4aa8ff")
                : "#2a2f3a")
          }
          Text("\(gpu.utilPct)%").font(.caption).bold()
        }
        // VRAM bar with OOM warning
        HStack(spacing: 2) {
          for seg in 0..<20 {
            Text("▉")
              .font(.caption)
              .foregroundColor(seg < gpu.vramUsedGB * 20 / gpu.vramTotalGB
                ? (gpu.vramUsedGB * 100 / gpu.vramTotalGB >= 92 ? "#ff5c5c" : "#b072ff")
                : "#2a2f3a")
          }
          Text("\(gpu.vramUsedGB)/\(gpu.vramTotalGB)G").font(.caption)
        }
      }
      .padding(6)
      .background(RoundedRectangle(cornerRadius: 8).fill("#161a22"))
      .onTapGesture { cmux("surface.focus", surface_id: gpu.ownerSurfaceId) }
    }

    Divider()

    // Host RAM
    HStack(spacing: 6) {
      Image(systemName: "memorychip")
      Text("RAM").font(.caption).bold()
      Spacer()
      Text("\(host.ramUsedGB)/\(host.ramTotalGB)G")
        .font(.caption)
        .foregroundColor(host.ramUsedGB * 100 / host.ramTotalGB >= 90 ? "#ff5c5c" : .primary)
    }
    HStack(spacing: 2) {
      for seg in 0..<24 {
        Text("▉").font(.caption)
          .foregroundColor(seg < host.ramUsedGB * 24 / host.ramTotalGB ? "#f0a14a" : "#2a2f3a")
      }
    }
    HStack(spacing: 6) {
      Image(systemName: "internaldrive")
      Text("Disk \(host.diskFreeGB)G free").font(.caption).foregroundColor("#8b95a5")
      Spacer()
      Text("CPU \(host.cpuPct)%").font(.caption).foregroundColor("#8b95a5")
    }
  }
  .padding(12)

  // RIGHT COLUMN: workflow
  VStack(alignment: .leading, spacing: 10) {
    // Active training runs
    HStack(spacing: 6) {
      Image(systemName: "waveform.path.ecg")
      Text("RUNS").font(.caption).bold().foregroundColor("#8b95a5")
      Spacer()
      Text("\(runs.count)").font(.caption).foregroundColor("#8b95a5")
    }
    if runs.isEmpty {
      Text("No active runs").font(.caption).foregroundColor("#8b95a5").padding(6)
    } else {
      ForEach(runs) { run in
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(run.status == "running" ? "●" : (run.status == "failed" ? "✕" : "✓"))
              .foregroundColor(run.status == "running" ? "#3ddc84"
                : (run.status == "failed" ? "#ff5c5c" : "#8b95a5"))
            Text(run.name).font(.caption).bold()
            Spacer()
            Text("ep \(run.epoch)/\(run.totalEpochs)").font(.caption).foregroundColor("#8b95a5")
          }
          HStack(spacing: 8) {
            Text("loss \(run.loss)").font(.caption).foregroundColor("#4aa8ff")
            Text("lr \(run.lr)").font(.caption).foregroundColor("#8b95a5")
            Spacer()
            Text("ETA \(run.etaMin)m").font(.caption).foregroundColor("#f0a14a")
          }
          // step progress
          HStack(spacing: 2) {
            for seg in 0..<18 {
              Text("▬").font(.caption)
                .foregroundColor(seg < run.step * 18 / run.totalSteps ? "#3ddc84" : "#2a2f3a")
            }
          }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill("#161a22"))
        .onTapGesture { cmux("surface.focus", surface_id: run.surfaceId) }
      }
    }

    Divider()

    // Dataset shortcuts
    HStack(spacing: 6) {
      Image(systemName: "tray.full")
      Text("DATASETS").font(.caption).bold().foregroundColor("#8b95a5")
    }
    ForEach(datasets) { ds in
      Button(action: {
        cmux("workspace.select", workspace_id: ds.workspaceId)
        cmux("surface.run", surface_id: ds.surfaceId, command: ds.mountCommand)
      }) {
        HStack(spacing: 8) {
          Image(systemName: ds.mounted ? "checkmark.circle.fill" : "circle")
            .foregroundColor(ds.mounted ? "#3ddc84" : "#8b95a5")
          VStack(alignment: .leading, spacing: 1) {
            Text(ds.name).font(.caption).bold()
            Text("\(ds.sizeGB)G · \(ds.rows) rows").font(.caption).foregroundColor("#8b95a5")
          }
          Spacer()
          Image(systemName: "arrow.right.circle").foregroundColor("#4aa8ff")
        }
        .padding(6)
      }
    }

    Divider()

    // Workspaces (live context)
    HStack(spacing: 6) {
      Image(systemName: "rectangle.3.group")
      Text("WORKSPACES").font(.caption).bold().foregroundColor("#8b95a5")
      Spacer()
      Text("\(workspaceCount)").font(.caption).foregroundColor("#8b95a5")
    }
    ForEach(workspaces) { ws in
      HStack(spacing: 6) {
        Text(ws.selected ? "▸" : " ").foregroundColor("#4aa8ff")
        Text(ws.title).font(.caption).bold(ws.selected)
        Spacer()
        Text("\(ws.tabs.count)").font(.caption).foregroundColor("#8b95a5")
      }
      .padding(4)
      .onTapGesture { cmux("workspace.select", workspace_id: ws.id) }
    }
  }
  .padding(12)
}
