package raw

import (
	"encoding/json"
	"testing"
)

func TestSizeDeviceKindIncludesLinuxAndWindows(t *testing.T) {
	for _, raw := range []string{"mac", "iphone", "ipad", "tui", "browser", "linux", "windows", "unknown"} {
		var kind SizeDeviceKind
		if err := json.Unmarshal([]byte(`"`+raw+`"`), &kind); err != nil {
			t.Fatalf("decode %q: %v", raw, err)
		}
		encoded, err := json.Marshal(kind)
		if err != nil || string(encoded) != `"`+raw+`"` {
			t.Fatalf("encode %q = %s, %v", raw, encoded, err)
		}
	}
}

func TestUnknownSizeDeviceKindDecodesAsGenericClient(t *testing.T) {
	var participant SizeParticipant
	row := `{"id":"c1","user_id":"u1","display_name":null,"device_kind":"quantum","device_name":null,` +
		`"device_id":null,"via":null,"viewport":null,"counts":true,"counts_override":null,"priority_key":"u1/quantum"}`
	if err := json.Unmarshal([]byte(row), &participant); err != nil {
		t.Fatalf("decode participant: %v", err)
	}
	if participant.DeviceKind != SizeDeviceKindUnknown {
		t.Fatalf("device kind = %q, want unknown", participant.DeviceKind)
	}
	var kind SizeDeviceKind
	if err := json.Unmarshal([]byte(`7`), &kind); err == nil {
		t.Fatal("a non-string device kind decoded")
	}
	// Encoding stays strict: the SDK never sends a kind it does not know.
	if _, err := json.Marshal(SizeDeviceKind("quantum")); err == nil {
		t.Fatal("encoded an unknown device kind")
	}
}
