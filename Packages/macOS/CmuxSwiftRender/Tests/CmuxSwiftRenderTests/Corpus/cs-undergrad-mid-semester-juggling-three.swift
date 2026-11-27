// cmux pomodoro study sidebar — single view expression.
// Conventions used by this sidebar (the interpreter has no `let` for structs/funcs,
// so these "model" values are expressed as array/dict literals inline):
//   - A "phase" is "focus" or "break"; here we render a focus block.
//   - tasks: each row is bound to one of my real cmux workspaces by index.
//
// Live-derived bits I lean on: workspaces (my courses), workspaceCount, selectedTitle.

let accent = "#FF6B5E"          // pomodoro tomato red
let dim = "#8A8F98"
let good = "#34D399"

// --- Session model (would be mutable + timer-driven; see missingFeatures) ---
let blockLength = 25            // minutes per focus block
let elapsedSec = 11 * 60 + 42   // 11:42 into the block (live tick in real life)
let totalSec = blockLength * 60
let remainingSec = totalSec - elapsedSec
let remMin = remainingSec / 60
let remSec = remainingSec % 60
let pct = (elapsedSec * 100) / totalSec   // 0..100 integer progress

// pomodoros completed this session (of 4 before a long break) + lifetime streak
let pomosDone = 2
let pomosPerSet = 4
let dayStreak = 6

// Today's checklist. completed flag + which workspace index it lives in.
let tasks = [
  ["title": "Finish CS phase-2 interpreter", "done": true,  "ws": 0, "tag": "CS"],
  ["title": "Linear algebra pset #7",        "done": false, "ws": 1, "tag": "MATH"],
  ["title": "Reading: distributed systems",   "done": false, "ws": 2, "tag": "DS"],
  ["title": "Push side-project sidebar PR",   "done": false, "ws": 0, "tag": "CS"]
]
let doneCount = (tasks[0]["done"] ? 1 : 0) + (tasks[1]["done"] ? 1 : 0) + (tasks[2]["done"] ? 1 : 0) + (tasks[3]["done"] ? 1 : 0)

VStack(alignment: .leading, spacing: 14) {

  // ===== HEADER: session goal + phase =====
  HStack(spacing: 6) {
    Image(systemName: "timer")
      .foregroundColor(accent)
    Text("FOCUS BLOCK")
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundColor(accent)
    Spacer()
    Text("\(pomosDone)/\(pomosPerSet)")
      .font(.caption)
      .foregroundColor(dim)
  }

  Text(selectedTitle)
    .font(.headline)
    .bold()

  // ===== COUNTDOWN =====
  HStack(alignment: .bottom, spacing: 2) {
    Text("\(remMin):\(remSec < 10 ? "0\(remSec)" : "\(remSec)")")
      .font(.system(size: 40, weight: .bold, design: .monospaced))
      .foregroundColor(remainingSec < 60 ? accent : .primary)
    Text("left")
      .font(.caption)
      .foregroundColor(dim)
      .padding(4)
  }

  // ===== PROGRESS BAR (hand-built from filled cells) =====
  // 20 segments; fill ceil(pct/5) of them.
  HStack(spacing: 2) {
    let filled = (pct + 4) / 5
    for i in 0..<20 {
      Rectangle()
        .frame(width: 6, height: 6)
        .foregroundColor(i < filled ? accent : dim)
        .cornerRadius(2)
    }
  }

  Divider()

  // ===== TASK CHECKLIST (each row launches its workspace) =====
  Text("TODAY  \(doneCount)/\(tasks.count)")
    .font(.caption)
    .fontWeight(.semibold)
    .foregroundColor(dim)

  ForEach(tasks) { t in
    HStack(spacing: 8) {
      Image(systemName: t["done"] ? "checkmark.circle.fill" : "circle")
        .foregroundColor(t["done"] ? good : dim)
        .onTapGesture {
          // checking a task = jump into the workspace it belongs to
          cmux("workspace.select", workspace_id: workspaces[t["ws"]].id)
          log("toggled: \(t["title"])")
        }
      Text(t["title"])
        .font(.caption)
        .foregroundColor(t["done"] ? dim : .primary)
        .strikethrough(t["done"])
      Spacer()
      Text(t["tag"])
        .font(.caption2)
        .foregroundColor(accent)
        .padding(3)
        .background(accent.opacity(0.12))
        .cornerRadius(4)
    }
    .padding(2)
    .onTapGesture {
      cmux("workspace.select", workspace_id: workspaces[t["ws"]].id)
    }
  }

  Divider()

  // ===== POMODORO SET DOTS =====
  HStack(spacing: 6) {
    for i in 0..<pomosPerSet {
      Image(systemName: i < pomosDone ? "circle.fill" : "circle")
        .foregroundColor(i < pomosDone ? accent : dim)
    }
    Spacer()
    // Start / pause the block — needs a real action + mutable timer
    Button(action: { cmux("pomodoro.toggle"); log("start/pause") }) {
      HStack(spacing: 4) {
        Image(systemName: "play.fill")
        Text("Start")
      }
      .font(.caption)
      .foregroundColor(.white)
      .padding(6)
      .background(accent)
      .cornerRadius(6)
    }
  }

  // ===== STREAK =====
  HStack(spacing: 6) {
    Image(systemName: "flame.fill")
      .foregroundColor("#FB923C")
    Text("\(dayStreak)-day streak")
      .font(.caption)
      .bold()
    Spacer()
    Text("keep it 🔥")
      .font(.caption2)
      .foregroundColor(dim)
  }
}
.padding(12)
