package cmux

import "context"

// MachineReadOptions selects the response format without granting execution rights.
type MachineReadOptions struct{ Catalog bool }

func (c *Client) ListMachinesWith(ctx context.Context, options MachineReadOptions) ([]*Machine, error) {
	return c.ListMachines(ctx, MachineListOptions{})
}

func (m *Machine) RefreshWith(ctx context.Context, options MachineReadOptions) (MachineSnapshot, error) {
	return m.Refresh(ctx)
}

func (c *Client) FindMachinesByNameWith(ctx context.Context, name string, options MachineReadOptions) ([]*Machine, error) {
	machines, err := c.ListMachinesWith(ctx, options)
	if err != nil {
		return nil, err
	}
	return filterMachines(machines, name), nil
}
