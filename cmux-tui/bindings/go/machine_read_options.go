package cmux

import (
	"context"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev2"
)

// MachineReadOptions selects the response format without granting execution rights.
type MachineReadOptions struct{ Catalog bool }

func (c *Client) ListMachinesWith(ctx context.Context, options MachineReadOptions) ([]*Machine, error) {
	return c.ListMachines(ctx, MachineListOptions{ReadOptions: ReadOptions{Extra: machineCatalogParams(options)}})
}

func (m *Machine) RefreshWith(ctx context.Context, options MachineReadOptions) (MachineSnapshot, error) {
	params := m.route.params()
	for name, value := range machineCatalogParams(options) {
		params[name] = value
	}
	var snapshot MachineSnapshot
	if err := m.client.readResource(ctx, wirev2.MachineGet, params, &snapshot); err != nil {
		return MachineSnapshot{}, err
	}
	m.mu.Lock()
	m.snapshot = &snapshot
	m.mu.Unlock()
	return snapshot, nil
}

func (c *Client) FindMachinesByNameWith(ctx context.Context, name string, options MachineReadOptions) ([]*Machine, error) {
	machines, err := c.ListMachinesWith(ctx, options)
	if err != nil {
		return nil, err
	}
	return filterMachines(machines, name), nil
}

func machineCatalogParams(options MachineReadOptions) map[string]JSONValue {
	if options.Catalog {
		return map[string]JSONValue{"catalog": true}
	}
	return nil
}

func (m *Machine) Refresh(ctx context.Context) (MachineSnapshot, error) {
	return m.RefreshWith(ctx, MachineReadOptions{})
}
