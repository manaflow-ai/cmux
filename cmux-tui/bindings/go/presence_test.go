package cmux

import (
	"encoding/json"
	"testing"
)

func TestPresenceConstructorsAndAccessors(t *testing.T) {
	var absent Presence[string]
	if !absent.IsAbsent() || absent.IsNull() {
		t.Fatalf("zero Presence = %#v", absent)
	}
	if _, ok := absent.Get(); ok {
		t.Fatal("absent Presence returned a value")
	}

	null := Null[string]()
	if null.IsAbsent() || !null.IsNull() {
		t.Fatalf("null Presence = %#v", null)
	}
	if _, ok := null.Get(); ok {
		t.Fatal("null Presence returned a value")
	}

	present := Value("cmux")
	if present.IsAbsent() || present.IsNull() {
		t.Fatalf("value Presence = %#v", present)
	}
	if value, ok := present.Get(); !ok || value != "cmux" {
		t.Fatalf("value Presence.Get() = %q, %t", value, ok)
	}
}

func TestRequiredNullableConstructorsAndAccessors(t *testing.T) {
	var unset RequiredNullable[string]
	if unset.IsSet() || unset.IsNull() {
		t.Fatalf("zero RequiredNullable = %#v", unset)
	}
	if _, err := json.Marshal(unset); err == nil {
		t.Fatal("unset RequiredNullable encoded successfully")
	}

	null := RequiredNull[string]()
	if !null.IsSet() || !null.IsNull() {
		t.Fatalf("null RequiredNullable = %#v", null)
	}

	present := RequiredValue("cmux")
	if !present.IsSet() || present.IsNull() {
		t.Fatalf("value RequiredNullable = %#v", present)
	}
	if value, ok := present.Get(); !ok || value != "cmux" {
		t.Fatalf("value RequiredNullable.Get() = %q, %t", value, ok)
	}
}

func TestCommandMapPreservesExplicitNull(t *testing.T) {
	params, err := commandMap(SetClientInfoOptions{
		Name: Null[string](),
	})
	if err != nil {
		t.Fatal(err)
	}
	value, exists := params["name"]
	if !exists || value != nil {
		t.Fatalf("name = %#v, exists = %t", value, exists)
	}
	if _, exists := params["kind"]; exists {
		t.Fatal("absent kind was encoded")
	}
}

func TestTerminalPlacementLifecycleIsExactLiteral(t *testing.T) {
	valid := `{
		"generation":"g",
		"key":"k",
		"lifecycle":"running",
		"pane":1,
		"registry_id":"r",
		"replayed":false,
		"screen":2,
		"surface":3,
		"terminal_id":null,
		"terminal_incarnation":null,
		"terminal_revision":4,
		"workspace":5
	}`
	var placement TerminalPlacement
	if err := json.Unmarshal([]byte(valid), &placement); err != nil {
		t.Fatal(err)
	}
	lifecycle, ok := placement.Lifecycle.Get()
	if !ok || lifecycle != TerminalPlacementLifecycleRunning {
		t.Fatalf("lifecycle = %q, %t", lifecycle, ok)
	}

	invalid := []byte(`{
		"generation":"g",
		"key":"k",
		"lifecycle":"exited",
		"pane":1,
		"registry_id":"r",
		"replayed":false,
		"screen":2,
		"surface":3,
		"terminal_id":null,
		"terminal_incarnation":null,
		"terminal_revision":4,
		"workspace":5
	}`)
	if err := json.Unmarshal(invalid, &placement); err == nil {
		t.Fatal("invalid TerminalPlacement lifecycle decoded successfully")
	}
}
