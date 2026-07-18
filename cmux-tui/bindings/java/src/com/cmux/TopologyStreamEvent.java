package com.cmux;

public sealed interface TopologyStreamEvent extends CmuxEvent permits TopologyDelta, TopologyResnapshotRequired {}
