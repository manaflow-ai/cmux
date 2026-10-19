package cmux

import (
	"encoding/json"
	"testing"
)

func TestMachineCatalogOwnerMetadata(t *testing.T) {
	for _, origin := range []string{"local", "cloud", "ssh", "server"} {
		raw, err := json.Marshal(map[string]any{"id": "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "name": "server",
			"origin": origin, "status": "running", "connectable": true, "deleted": false, "recoverable": false,
			"platform": map[string]any{"os": "linux", "arch": "aarch64"}, "capabilities": []string{"terminal", "agent_session"}})
		if err != nil {
			t.Fatal(err)
		}
		machine, err := decodeValue[MachineSnapshot](raw, "machine")
		if err != nil {
			t.Fatal(err)
		}
		if machine.Origin != origin || machine.Platform == nil || machine.Platform.OS == nil || *machine.Platform.OS != "linux" || len(machine.Capabilities) != 2 {
			t.Fatalf("owner metadata lost: %+v", machine)
		}
	}
}
