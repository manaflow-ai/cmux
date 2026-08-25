// panel-todo: right-sidebar demo. A scratch checklist living entirely in
// sidebar signals (resets on reload) - shows TextField, signals, context
// menus, and derived state in the JS lane.
//   cp Examples/CustomSidebars/panel-todo.js ~/.config/cmux/sidebars/
//   cmux right-sidebar set custom panel-todo

const [items, setItems] = signal([]);
let nextId = 1;

function addItem(text) {
  const title = (text ?? "").trim();
  if (!title) return;
  setItems([...items(), { id: String(nextId++), title, done: false }]);
}

function toggle(id) {
  setItems(items().map((t) => (t.id === id ? { ...t, done: !t.done } : t)));
}

function remove(id) {
  setItems(items().filter((t) => t.id !== id));
}

const remaining = computed(() => items().filter((t) => !t.done).length);

sidebar(() =>
  VStack({ spacing: 8 }, [
    HStack({ spacing: 6 }, [
      Text("Scratch").font(14).weight("semibold"),
      Spacer(),
      Text(() => (items().length ? remaining() + " left" : ""))
        .font(11).color("tertiary"),
    ]).paddingHorizontal(10),

    TextField("", {
      placeholder: "Add and press Return",
      onSubmit: (t) => addItem(t),
    })
      .paddingHorizontal(10),

    ForEach(
      { items, key: (t) => t.id },
      (t) =>
        HStack({ spacing: 8 }, [
          Image(() => (t().done ? "checkmark.circle.fill" : "circle"))
            .font(13)
            .color(() => (t().done ? "#34C759" : "tertiary")),
          Text(() => t().title)
            .font(13).lineLimit(1).truncation("tail")
            .color(() => (t().done ? "tertiary" : "primary")),
          Spacer(),
        ])
          .paddingHorizontal(10).paddingVertical(6)
          .cornerRadius(8)
          .hoverBackground("#7f7f7f24")
          .frame({ maxWidth: "infinity" })
          .onTap(() => toggle(t().id))
          .contextMenu([
            Button("Remove", () => remove(t().id)).destructive(),
          ])
    ),

    Text(() => (items().length === 0 ? "Nothing yet. Type above." : ""))
      .font(11).color("tertiary").paddingHorizontal(10),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
