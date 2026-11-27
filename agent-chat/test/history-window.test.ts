import { compactTurnGroups, type TurnGroup } from "../src/turns";

const groups: TurnGroup[] = Array.from({ length: 5 }, (_, index) => ({
  id: `turn-${index}`,
  activity: [],
  done: true,
}));
const compacted = compactTurnGroups(groups);
if (compacted.folded.length !== 2 || compacted.visible.length !== 3) {
  throw new Error(`history window should keep the newest three turns visible: ${compacted.folded.length}/${compacted.visible.length}`);
}
if (compacted.folded[0] !== groups[0] || compacted.visible[0] !== groups[2]) {
  throw new Error("history window should preserve stable group objects and order");
}
if (compactTurnGroups(groups, 20).folded.length !== 0) {
  throw new Error("history window should avoid folding when the visible tail covers the transcript");
}

console.log("history window: OK");
